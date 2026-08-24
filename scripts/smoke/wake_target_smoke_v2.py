#!/usr/bin/env python3
"""A durable wake may only fire a baked module that opted in (rove#495).

A `_sched/` record names its own dispatch target, and `_sched/` is
customer-writable by design (`reserved.zig`'s `SHIM_WRITABLE_PREFIXES`) so the
`schedule` shim can arm wakes from handler context. `fireDurableWakeActivation`
grants `is_system_module` from the module PATH, so before this gate two
`kv.set` calls invoked ANY baked module, as a system module, with a `msg` the
tenant chose.

Nothing was exploitable through that at the time — the baked modules are
individually defensive — which is exactly why it needed a gate rather than a
patch: the safety was ten independent choices, re-checked by hand, with
nothing asserting it stays that way.

Three things have to hold together, and each would hide a broken version of
the others:

  1. a wake armed at a non-targetable baked module does not run it;
  2. the refused entry is DROPPED, not retried — a refusal that left the row
     in place would re-offer it every tick, turning a closed door into a 1 Hz
     dispatch loop;
  3. a legitimate wake still fires, both at a customer module (`schedule`) and
     at a baked one (`webhook.send({at})` → `__system/webhook_fire`).

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

HANDLER_SRC = r'''
import schedule from "@rewind/schedule";

export function handler() { return "ready"; }

// Arm a wake by hand at an arbitrary baked module — the raw shape the
// `schedule` shim writes, which any handler can write directly.
export function armBaked(target) {
    const sid = "hand-" + target.replace(/[^a-z_]/g, "");
    const when = String(BigInt(Date.now()) * 1_000_000n);
    kv.set("_sched/by_id/" + sid, JSON.stringify({
        // The record version the tick switches on (RecordVersions.sched in
        // src/js/globals.zig). This handler is a SECOND implementation of
        // the record shape — the point of the smoke is that any handler can
        // write one — so it has to carry `v` or the tick drops it as
        // unversioned and this stops testing the bad-TARGET path it exists
        // to test.
        v: 1,
        when_ns: when,
        target: target,
        msg: { id: "probe", sid: sid },
        key: "hand/" + sid,
    }));
    kv.set("_sched/by_time/" + when.padStart(20, "0") + "/" + sid, "");
    return sid;
}

// Did the entry survive? A refused target must leave nothing behind, or the
// tick re-offers it forever.
export function schedRow(sid) {
    return kv.get("_sched/by_id/" + sid) === null ? "gone" : "present";
}

// A legitimate wake at the tenant's OWN module — the supported path, which
// the gate must not touch.
export function armSchedule() {
    schedule({ in: 1000 }, "index.mjs.onWake", { tag: "own" }, { key: "own-wake" });
    return "armed";
}

export function onWake() {
    kv.set("wake/fired", "yes");
    return { status: 200 };
}

export function wakeFired() { return kv.get("wake/fired") || "no"; }

// A legitimate wake at a BAKED module, through the supported verb.
export function armSend(url) {
    const at = BigInt(Date.now() + 1500) * 1_000_000n;
    webhook.send(url, { method: "POST", body: "scheduled", at: at });
    return "armed";
}
'''


class Sink(BaseHTTPRequestHandler):
    received: list[str] = []
    lock = threading.Lock()

    def do_POST(self):  # noqa: N802
        n = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(n).decode("utf-8", "replace") if n else ""
        with Sink.lock:
            Sink.received.append(body)
        self.send_response(200)
        self.send_header("content-length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

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
    sink_url = f"http://127.0.0.1:{httpd.server_address[1]}/hook"
    threading.Thread(target=httpd.serve_forever, daemon=True).start()

    with V2Cluster.spawn("waketgt", nodes=1) as c:
        r = c.provision(TENANT)
        check("provision → 200", r.status == 200, f"got {r.status}")
        # `webhook.send` needs outbound, which the free tier does not grant
        # (#336) — this smoke is about wake targeting, not about the quota.
        c.set_plan(TENANT, json.dumps({"tier": "pro"}))
        try:
            pkgs, imports = c.firstparty_packages(["@rewind/schedule"])
            c.deploy_with_packages(TENANT, {"index.mjs": rpc_wrap(HANDLER_SRC)},
                                   pkgs, imports)
        except RuntimeError as e:
            check("deploy", False, str(e))
            print(f"FAILURES: {failures}")
            return 1
        ready = c.wait_for_handler(TENANT, "/?fn=handler", want_body="ready")
        check("deployment loaded", ready.status == 200, f"got {ready.status}")

        # ── 1 + 2: a non-targetable baked module is refused and dropped ──
        print("\nstep: wakes armed by hand at non-targetable baked modules")
        for target in ["__system/blob_compose", "__system/webhook_onresult",
                       "__system/static", "__system/webhook_fire.mjs.default"]:
            r = c.get(TENANT, f"/?fn=armBaked&args={_args(target)}")
            sid = r.body.strip().strip('"')
            check(f"armed {target}", r.status == 200 and sid, f"got {r.body[:80]!r}")
            # The tick runs at 1 Hz; give it several passes so a retry loop
            # would have shown up as a surviving row.
            time.sleep(4.0)
            s = c.get(TENANT, f"/?fn=schedRow&args={_args(sid)}")
            check(f"{target}: entry dropped, not retried", "gone" in s.body,
                  f"row is {s.body[:40]!r} — a surviving row re-fires every tick")

        # ── 3: the supported paths still fire ────────────────────────────
        print("\nstep: a legitimate wake at the tenant's own module")
        r = c.get(TENANT, "/?fn=armSchedule")
        check("schedule armed", "armed" in r.body, f"got {r.body[:80]!r}")
        fired = False
        deadline = time.time() + 25
        while time.time() < deadline:
            if "yes" in c.get(TENANT, "/?fn=wakeFired").body:
                fired = True
                break
            time.sleep(0.5)
        check("customer wake fired", fired)

        print("\nstep: a legitimate wake at a baked module (webhook.send({at}))")
        r = c.get(TENANT, f"/?fn=armSend&args={_args(sink_url)}")
        check("scheduled send armed", "armed" in r.body, f"got {r.body[:80]!r}")
        delivered = False
        deadline = time.time() + 25
        while time.time() < deadline:
            with Sink.lock:
                delivered = "scheduled" in Sink.received
            if delivered:
                break
            time.sleep(0.5)
        check("__system/webhook_fire still fires", delivered)
        if not delivered:
            c.dump_node_log(grep=["wake", "webhook_fire", "targetable"])

    print()
    if failures:
        print(f"FAILURES: {failures}")
        return 1
    print("PASS — only opted-in baked modules are wake-targetable, refusals "
          "drop rather than loop, and legitimate wakes still fire")
    return 0


if __name__ == "__main__":
    sys.exit(main())
