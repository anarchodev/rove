#!/usr/bin/env python3
"""V2 port of `heldsync_smoke.py` — the §6.4 held-synchronous third-party
call on the `V2Cluster` harness (branch `v2`).

ONE synchronous client request to acme's `/heldsync`:

  client ──POST /heldsync {target,tag}──▶ acme open hop
     open: webhook.send(target) + return __rove_next(heldsync/onresult#onResult)
        → the §6.4 binding stamps the lone `_send/owed/` put's completion
          as this continuation's resume; the entity parks (held; no response)
     webhook libcurl fires → wb echoes → webhook_onresult → resumeIfBound
        → onResult runs → terminal → resolveParked flushes to the open socket
  ◀── 200 "heldsync:v:echoed:v"  (the one request returns, resumed)

Single-node V2 (the open hop park + the webhook completion + the resume are
all the same worker; cross-worker is orthogonal). The held POST rides the
FRONT door; the resume is driven by the internal webhook completion (not a
second client request), so there is no front-door head-of-line concern.

V2 outbound: the worker binds 0.0.0.0, so on-box libcurl reaches the same
node over loopback at `http://wb.localhost:<node_port>/echo`; the
`wb.<suffix>` Host carries the tenant routing (a bare 127.0.0.1 URL would
404). V2 does not enforce the loopback/plaintext SSRF block on outbound, so
no `--dev-webhook-unsafe` is needed (it isn't wired on `rewind` anyway).

Dropped from V1 (V2-irrelevant): TLS/https, leader-direct addressing /
discover_leader, seed_manifest, workers_per_node, --dev-webhook-unsafe.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, PUBLIC_SUFFIX  # noqa: E402

# Handlers verbatim from the V1 demo tenant
# (examples/loop46-demo-tenants/acme/heldsync/{index,onresult}.mjs and
# examples/loop46-demo-tenants/wb/index.mjs).
HELDSYNC_SRC = r"""export default function () {
    const req = JSON.parse(request.body);
    const opts = {
        url: req.target,
        method: "POST",
        body: JSON.stringify({ from: "heldsync", tag: req.tag }),
        headers: { "content-type": "application/json" },
        max_attempts: 1,
    };
    if (req.send_timeout_ms) opts.timeout_ms = req.send_timeout_ms;
    webhook.send(opts);
    return __rove_next("heldsync/onresult", {
        fn: "onResult",
        ctx: { tag: req.tag, tries: 0, retry_to: req.retry_to || null },
    });
}
"""

ONRESULT_SRC = r"""export function onResult(ctx, outcome) {
    if (!outcome.ok) {
        if (ctx.retry_to && ctx.tries < 1) {
            webhook.send({
                url: ctx.retry_to,
                method: "POST",
                body: JSON.stringify({ from: "heldsync-retry", tag: ctx.tag }),
                headers: { "content-type": "application/json" },
                max_attempts: 1,
            });
            return __rove_next("heldsync/onresult", {
                fn: "onResult",
                ctx: { tag: ctx.tag, tries: ctx.tries + 1, retry_to: null },
            });
        }
        response.status = 502;
        return "heldsync upstream failed: " + (outcome.error || outcome.reason || outcome.status);
    }
    return "heldsync:" + ctx.tag + ":" + outcome.body;
}
"""

WB_SRC = r"""export default function () {
    let payload = null;
    try { payload = JSON.parse(request.body); } catch (_) {}
    const tag = (payload && payload.tag) || "<no-tag>";
    response.status = 200;
    return "echoed:" + tag;
}
"""

READY_SRC = 'export function handler() { return "ready"; }\n'


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("heldsync", nodes=1) as c:
        print("step 1: provision tenants 'acme' + 'wb' via the CP")
        r = c.provision("acme")
        check("provision acme → 204", r.status == 204, f"got {r.status} {r.body!r}")
        r = c.provision("wb")
        check("provision wb → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 2: deploy wb (echo) + acme (heldsync open + resume hops)")
        try:
            c.deploy_handlers("wb", {"index.mjs": WB_SRC, "echo/index.mjs": WB_SRC})
            dep_id = c.deploy_handlers("acme", {
                "index.mjs": READY_SRC,
                "heldsync/index.mjs": HELDSYNC_SRC,
                "heldsync/onresult.mjs": ONRESULT_SRC,
            })
            check("deploy_handlers → dep_id", bool(dep_id), f"dep_id={dep_id}")
        except RuntimeError as e:
            check("deploy_handlers", False, str(e))
            dep_id = None

        if not dep_id:
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print("step 3: wait for both deployments to load")
        ready = c.wait_for_handler("acme", "/?fn=handler", want_body="ready")
        check("acme loaded", ready.status == 200 and "ready" in ready.body,
              f"got {ready.status} {ready.body!r}")
        # wb echoes (POST) — poll it directly so the first heldsync hop isn't
        # racing the wb cold-start deploy.
        wb_url = f"http://wb.{PUBLIC_SUFFIX}:{c.node_ports[0]}/echo"
        deadline = time.time() + 25.0
        wb_ok = False
        while time.time() < deadline:
            w = c.node_request("/echo", method="POST", host=f"wb.{PUBLIC_SUFFIX}",
                               headers={"content-type": "application/json"},
                               data=json.dumps({"tag": "sanity"}))
            if w.status == 200 and w.body == "echoed:sanity":
                wb_ok = True
                break
            time.sleep(0.4)
        check("wb (third party) reachable; echoes", wb_ok, f"got {w.status} {w.body!r}")
        if not (ready.status == 200 and wb_ok):
            c.dump_node_log(grep=["deploy", "loader", "manifest", "resolve", "404",
                                  "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print("step 4: THE held-synchronous request — one POST, resumed body")
        t0 = time.monotonic()
        r = c.request("acme", "/heldsync", method="POST",
                      headers={"content-type": "application/json"},
                      data=json.dumps({"target": wb_url, "tag": "v"}),
                      timeout=30.0)  # > 25s §6.4 hold deadline so a 504 still returns
        elapsed = time.monotonic() - t0
        check("heldsync → 200", r.status == 200,
              f"got {r.status} {r.body!r} ({elapsed:.2f}s)")
        check("heldsync body == 'heldsync:v:echoed:v'", r.body == "heldsync:v:echoed:v",
              f"got {r.body!r} ({elapsed:.2f}s)")
        check("heldsync resumed (not the deadline-504 path)", elapsed < 15.0,
              f"correct body but in {elapsed:.1f}s — that's the §6.4 deadline, not the resume")
        if r.status != 200:
            c.dump_node_log(grep=["deploy", "loader", "resolve", "404", "error", "warn",
                                  "webhook", "send", "owed", "resume", "park", "held",
                                  "continuation"])
        if r.status == 200 and r.body == "heldsync:v:echoed:v":
            print(f"  ok  held-synchronous call resumed: one POST → '{r.body}' "
                  f"in {elapsed:.2f}s (resume, not deadline)")

        print("step 5: failure outcome — dead target → handler-authored 502")
        dead = f"http://wb.{PUBLIC_SUFFIX}:9/"  # nothing on :9 → fast conn-refused
        t0 = time.monotonic()
        r = c.request("acme", "/heldsync", method="POST",
                      headers={"content-type": "application/json"},
                      data=json.dumps({"target": dead, "tag": "vf"}),
                      timeout=30.0)
        el = time.monotonic() - t0
        check("failure variant → 502 'heldsync upstream failed:'",
              r.status == 502 and r.body.startswith("heldsync upstream failed:"),
              f"got {r.status} {r.body!r} ({el:.1f}s)")
        check("failure variant fast (not deadline)", el < 15.0,
              f"took {el:.1f}s — not the fast failure path")
        if r.status == 502:
            print(f"  ok  failure outcome → handler-authored 502 in {el:.2f}s: '{r.body}'")

        print("step 6: recipe-1 real-retry — dead → retry_to, effectful resume hop")
        t0 = time.monotonic()
        r = c.request("acme", "/heldsync", method="POST",
                      headers={"content-type": "application/json"},
                      data=json.dumps({"target": dead, "tag": "vr", "retry_to": wb_url}),
                      timeout=30.0)
        el = time.monotonic() - t0
        check("recipe-1 real-retry → 200 'heldsync:vr:echoed:vr'",
              r.status == 200 and r.body == "heldsync:vr:echoed:vr",
              f"got {r.status} {r.body!r} ({el:.1f}s)")
        check("recipe-1 fast (not deadline)", el < 15.0, f"took {el:.1f}s")
        if r.status == 200 and r.body == "heldsync:vr:echoed:vr":
            print(f"  ok  recipe-1 real-retry: chained dead→retry_to, terminal 200 in "
                  f"{el:.2f}s — body='{r.body}'")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS held-synchronous (§6.4) smoke (v2)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
