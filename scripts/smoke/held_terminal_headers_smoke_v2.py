#!/usr/bin/env python3
"""Held-chain terminal response fidelity — headers survive the resume path.

A held `after.fetch` chain's TERMINAL response must be indistinguishable on
the wire from a plain dispatch response: the auto `content-type:
application/json` for object returns, and any handler-set response headers,
must arrive at the client. The offline harness (`rewind test`) compares
bodies only, so a resume path that drops headers is invisible there — this
smoke is the wire-level guard (found via the rove#320 billing rehearsal:
the dashboard parsed a held terminal's JSON as text because the
content-type never arrived).

Covers all three delivery arms:
  /plain — no chain (control; the inbound terminal path)
  /one   — one held hop, READ-ONLY terminal (`resolveParked` arm)
  /two   — two held hops, terminal hop WRITES kv
           (`proposeAndParkContResume` → raft-commit → ship arm),
           plus a handler-set custom header on the terminal
"""

from __future__ import annotations

import sys
import urllib.parse as up
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap, PUBLIC_SUFFIX  # noqa: E402

UP_SRC = 'export function handler() { return "upstream-body\\n"; }\n'

HR_SRC = """\
export function done1() {
  return { ok: true, hops: 1, marker: "held-terminal-1", upstream: request.status };
}
export function mid() {
  const u = (request.ctx && request.ctx.u) || "";
  after.fetch(u, { method: "GET", on: "done2", ctx: { u } });
  return next();
}
export function done2() {
  kv.set("held/last", String(Date.now()));
  response.headers = { "x-held-terminal": "yes" };
  return { ok: true, hops: 2, marker: "held-terminal-2", upstream: request.status };
}
export default function () {
  const q = new URLSearchParams(request.query || "");
  const u = q.get("u") || "";
  if (request.path === "/plain") return { ok: true, hops: 0, marker: "held-terminal-0" };
  if (request.path === "/one") {
    after.fetch(u, { method: "GET", on: "done1" });
    return next();
  }
  if (request.path === "/two") {
    after.fetch(u, { method: "GET", on: "mid", ctx: { u } });
    return next();
  }
  response.status = 404;
  return { error: "unknown path" };
}
"""


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("heldhdrs", nodes=1) as c:
        print("step 1: provision + deploy upstream (up) and held-chain tenant (hr)")
        r = c.provision("up")
        check("provision up", r.status == 200, f"{r.status}")
        r = c.provision("hr")
        check("provision hr", r.status == 200, f"{r.status}")
        c.deploy_handlers("up", {"index.mjs": rpc_wrap(UP_SRC)})
        c.deploy_handlers("hr", {"index.mjs": HR_SRC})
        r = c.wait_for_handler("up", "/?fn=handler", want_body="upstream-body")
        check("upstream serves", r.status == 200, f"{r.status} {r.body!r}")
        r = c.wait_for_handler("hr", "/plain", want_body="held-terminal-0")
        check("hr serves", r.status == 200, f"{r.status} {r.body!r}")

        u = up.quote(f"http://up.{PUBLIC_SUFFIX}:{c.front_port}/?fn=handler")

        def ct_of(resp):
            return {k.lower(): v for k, v in resp.headers.items()}.get("content-type", "")

        print("step 2: control — plain object return carries application/json")
        r = c.get("hr", "/plain")
        check("/plain json content-type",
              r.status == 200 and "application/json" in ct_of(r) and "held-terminal-0" in r.body,
              f"status={r.status} ct={ct_of(r)!r}")

        print("step 3: read-only held terminal carries application/json")
        r = c.get("hr", f"/one?u={u}", timeout=30.0)
        check("/one json content-type",
              r.status == 200 and "application/json" in ct_of(r) and "held-terminal-1" in r.body,
              f"status={r.status} ct={ct_of(r)!r} body={r.body[:120]!r}")

        print("step 4: writing held terminal carries json + handler header")
        r = c.get("hr", f"/two?u={u}", timeout=30.0)
        hdrs = {k.lower(): v for k, v in r.headers.items()}
        check("/two json content-type",
              r.status == 200 and "application/json" in ct_of(r) and "held-terminal-2" in r.body,
              f"status={r.status} ct={ct_of(r)!r} body={r.body[:120]!r}")
        check("/two handler-set header survives",
              hdrs.get("x-held-terminal") == "yes", f"x-held-terminal={hdrs.get('x-held-terminal')!r}")

        if failures:
            c.dump_node_log(grep=["error", "warn", "cont", "resume"])

    print("PASS" if not failures else f"FAIL: {failures}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
