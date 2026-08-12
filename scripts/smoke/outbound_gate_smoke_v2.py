#!/usr/bin/env python3
"""The outbound quota binds EVERY egress path, not just the inline one, and
a plan that grants outbound still works (rove#336).

Outbound is what makes a tenant that cost an email address to create useful
as a spam relay, so the free tier grants none (`plan.RateLimitCaps.
outbound_enabled`) and the quota is enforced at the frozen fetch native
(`bindings/http.zig`'s `outboundRateOk`) — never in a JS shim, which a
tenant-pinned package could route around.

Two tenants, three paths, opposite outcomes. Both halves matter: a
refusal-only smoke passes just as well when outbound is broken outright, so
the granted tenant is the control that proves these are gates and not
breakage.

  A. inline    — `webhook.send(url)` fires from handler context.
  B. deferred  — `webhook.send(url, { at: now + Δ })` writes a durable
                 marker plus a scheduler entry; the baked
                 `__system/webhook_fire` fires it later.
  C. laundered — the handler hand-writes the same `_send/owed/{id}` and
                 `_sched/` rows itself. Both prefixes are customer-writable
                 by design (`reserved.zig`'s `SHIM_WRITABLE_PREFIXES`), so
                 this needs no shim and no privileged surface.

B and C are the paths that made the quota opt-in: both fire as
`is_system_module`, which used to be exempt as "platform re-issuing an
already-admitted send". Nothing at that seam can tell an admitted send from
an invented one — the marker is customer data — so the exemption meant a
tenant bypassed its budget by deferring. Keep all three here: a fix that
only binds A is the bug again.

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

# The tenant that may not egress. No plan blob is installed for it at all —
# that is the point: a provisioned tenant has no plan row, so the free tier
# is what a real signup actually runs under.
DENIED = "acme"
# The tenant that may. `pro` grants outbound in the tier table.
GRANTED = "wb"
GRANTED_PLAN = json.dumps({"tier": "pro"})

# How long to wait for a deferred/laundered fire. The scheduler ticks at
# 1 Hz and the arm is ~1.5s out.
FIRE_WAIT_S = 25.0

HANDLER_SRC = r'''
export function handler() { return "ready"; }

// The other side of the gate: platform-internal doors (`*.internal`) are
// storage / control-plane I/O, not third-party egress, so a tenant with no
// outbound budget still reads and writes its own objects. `blob.put` lowers
// to `rove-blob.internal` through the same fetch native the gate sits on —
// if the gate ever stops discriminating, this is what breaks.
export function storage() {
    kv.set("gate/probe", "kv-ok");
    const hash = blob.put("bytes", { contentType: "text/plain", on: "stored" });
    return "storage-ok:" + kv.get("gate/probe") + ":" + (hash ? "hashed" : "nohash");
}

export function stored() { return { status: 200 }; }

// (A) inline third-party egress from handler context.
export function inline(url, tag) {
    try {
        webhook.send(url, { method: "POST", body: tag });
        return "sent";
    } catch (e) {
        return "refused:" + ((e && e.code) || String(e));
    }
}

// (B) deferred egress — the same verb with `at:`. No fetch is issued from
// handler context; `__system/webhook_fire` issues it when the wake is due.
export function deferred(url, tag, delay_ms) {
    const at = BigInt(Date.now() + delay_ms) * 1_000_000n;
    try {
        webhook.send(url, { method: "POST", body: tag, at: at });
        return "armed";
    } catch (e) {
        return "refused:" + ((e && e.code) || String(e));
    }
}

// (C) laundered egress — hand-write the marker + scheduler rows the shim
// would have written, as ordinary customer kv writes.
export function launder(url, tag, delay_ms) {
    const id = "laundered-" + tag;
    kv.set("_send/owed/" + id, JSON.stringify({
        url: url,
        method: "POST",
        body: tag,
        headers: {},
        attempts: 0,
        max_attempts: 1,
        on_result: null,
        context: null,
    }));
    const sid = "laundersched-" + tag;
    const when = String(BigInt(Date.now() + delay_ms) * 1_000_000n);
    kv.set("_sched/by_id/" + sid, JSON.stringify({
        when_ns: when,
        target: "__system/webhook_fire",
        msg: { id: id },
        key: "_send/" + id,
    }));
    kv.set("_sched/by_time/" + when.padStart(20, "0") + "/" + sid, "");
    return "armed";
}
'''


class Sink(BaseHTTPRequestHandler):
    """Records every delivered body. Each body is the calling tenant's tag,
    so an arrival names which tenant and which path produced it."""

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


def delivered(tag: str) -> bool:
    with Sink.lock:
        return tag in Sink.received


def await_delivery(tag: str, timeout_s: float = FIRE_WAIT_S) -> bool:
    """True as soon as `tag` arrives. A pass returns early; proving a
    NON-delivery necessarily costs the full window."""
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if delivered(tag):
            return True
        time.sleep(0.25)
    return False


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    httpd = HTTPServer(("127.0.0.1", 0), Sink)
    sink_url = f"http://127.0.0.1:{httpd.server_address[1]}/hook"
    threading.Thread(target=httpd.serve_forever, daemon=True).start()

    with V2Cluster.spawn("outbound", nodes=1) as c:
        for t in (DENIED, GRANTED):
            # DENIED opts out of the harness's default outbound grant — it has
            # to run under what a real signup resolves to, or this smoke tests
            # nothing. That opt-out is also what keeps the harness default
            # from silently un-testing the free tier everywhere else.
            r = c.provision(t, outbound=(t == GRANTED))
            check(f"provision {t} → 200", r.status == 200, f"got {r.status}")
            try:
                c.deploy_handlers(t, {"index.mjs": rpc_wrap(HANDLER_SRC)})
            except RuntimeError as e:
                check(f"deploy {t}", False, str(e))
                print(f"FAILURES: {failures}")
                return 1
            ready = c.wait_for_handler(t, "/?fn=handler", want_body="ready")
            check(f"{t} deployment loaded", ready.status == 200, f"got {ready.status}")

        # GRANTED gets a paid plan; DENIED deliberately gets none, so it runs
        # under whatever a freshly provisioned tenant actually resolves to.
        r = c.set_plan(GRANTED, GRANTED_PLAN)
        check("plan: pro installed on the granted tenant", r.status == 204, f"got {r.status}")

        # ── the denied tenant: every path refuses ────────────────────────
        print(f"\nstep: {DENIED} (free tier — no outbound)")
        r = c.get(DENIED, f"/?fn=inline&args={_args(sink_url, 'denied-inline')}")
        check("A: inline refused as outbound_not_enabled",
              "refused:outbound_not_enabled" in r.body, f"got {r.body[:120]!r}")

        r = c.get(DENIED, f"/?fn=deferred&args={_args(sink_url, 'denied-deferred', 1500)}")
        check("B: deferred arm accepted or refused", r.status == 200,
              f"got {r.status} {r.body[:120]!r}")

        r = c.get(DENIED, f"/?fn=launder&args={_args(sink_url, 'denied-laundered', 1500)}")
        check("C: launder handler ran", r.status == 200,
              f"got {r.status} {r.body[:120]!r}")

        # The carve-out: no outbound must not mean no storage.
        r = c.get(DENIED, "/?fn=storage")
        check("internal doors still open (kv + blob) with outbound off",
              "storage-ok:kv-ok:hashed" in r.body, f"got {r.status} {r.body[:160]!r}")

        # ── the granted tenant: every path delivers ──────────────────────
        print(f"\nstep: {GRANTED} (pro — outbound granted)")
        r = c.get(GRANTED, f"/?fn=inline&args={_args(sink_url, 'granted-inline')}")
        check("A: inline accepted", "sent" in r.body, f"got {r.body[:120]!r}")

        r = c.get(GRANTED, f"/?fn=deferred&args={_args(sink_url, 'granted-deferred', 1500)}")
        check("B: deferred armed", "armed" in r.body, f"got {r.body[:120]!r}")

        r = c.get(GRANTED, f"/?fn=launder&args={_args(sink_url, 'granted-laundered', 1500)}")
        check("C: launder armed", "armed" in r.body, f"got {r.body[:120]!r}")

        # Wait on the granted deliveries first: they are the ones expected to
        # arrive, so the wait is bounded by a real signal rather than by a
        # timeout, and by the time they land the denied fires are long due.
        print("\nstep: settle")
        check("A: granted inline delivered", await_delivery("granted-inline"))
        check("B: granted deferred delivered", await_delivery("granted-deferred"))
        check("C: granted laundered delivered", await_delivery("granted-laundered"))

        # Give the denied tenant's wakes the same wall-clock the granted ones
        # got, then assert silence.
        time.sleep(3.0)
        for tag, label in (("denied-inline", "A"), ("denied-deferred", "B"),
                           ("denied-laundered", "C")):
            was = delivered(tag)
            check(f"{label}: denied egress never reached the sink", not was,
                  "delivered despite a plan granting no outbound" if was else "")

        with Sink.lock:
            got = list(Sink.received)
        print(f"\n  sink received: {got}")
        if any(t.startswith("denied") for t in got):
            c.dump_node_log(grep=["outbound", "webhook_fire", "not enabled"])

    print()
    if failures:
        print(f"FAILURES: {failures}")
        return 1
    print("PASS — outbound refused on every path for a tenant without it, "
          "delivered on every path for one with it")
    return 0


if __name__ == "__main__":
    sys.exit(main())
