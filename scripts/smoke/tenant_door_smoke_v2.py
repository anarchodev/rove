#!/usr/bin/env python3
"""Tenant-door smoke — the inter-tenant fast path (`REWIND_INTERNAL_FRONT`).

When `REWIND_INTERNAL_FRONT` is set, an outbound fetch whose host is one of
OUR platform tenant hostnames (`*.{REWIND_PUBLIC_SUFFIX}` /
`*.{REWIND_SYSTEM_SUFFIX}`) pins its connect (CURLOPT_RESOLVE) to the
configured internal front addresses — the private plane — instead of
resolving public DNS, so tenant→tenant calls never hairpin through the
public edge. Everything else is identical to the public path: the front
routes by Host, the target tenant sees an ordinary inbound request.

Topology: single node + front, `REWIND_INTERNAL_FRONT=127.0.0.1` injected
via the environment (workers inherit `os.environ`). `acme` fires a
`webhook.send` at `http://wb.<suffix>:<front_port>/echo` — the host
suffix-matches `REWIND_PUBLIC_SUFFIX`, so the transfer takes the door.

Asserted:
  - boot log: the worker enabled the tenant door (env wiring)
  - the `httpresult` on_result callback ran with `ok:true status:200` and
    the echo body — the delivery round-tripped through the pinned path
  - worker log has exactly ONE "tenant door" pin line, naming the wb host
    (the door fired for the inter-tenant call and for nothing else)

The exact pin string (host:port:addrs) and the negative cases (foreign
hosts, label-boundary, scheme gate, unconfigured door) are covered by the
inline Zig tests in `src/js/fetch_engine.zig`; curl's CURLOPT_RESOLVE
behavior is the same mechanism every outbound smoke already exercises via
the SSRF rebinding pin.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

# MUST precede V2Cluster.spawn — workers inherit os.environ.
os.environ["REWIND_INTERNAL_FRONT"] = "127.0.0.1"

from smoke_lib_v2 import V2Cluster, PUBLIC_SUFFIX, rpc_wrap  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEMO = REPO_ROOT / "examples" / "loop46-demo-tenants"


def _src(rel: str) -> str:
    return (DEMO / rel).read_text()


HTTPFIRE_SRC = _src("acme/httpfire/index.mjs")
HTTPRESULT_SRC = _src("acme/httpresult.mjs")
WB_SRC = _src("wb/index.mjs")
ACME_INDEX_SRC = 'export function handler() { return "acme-ready"; }\n'

TAG = "via-tenant-door"


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("tdoor", nodes=1) as c:
        worker_log = Path(c.log_paths["n1"])

        print("step 1: provision + deploy acme (httpfire) and wb (echo)")
        r = c.provision("acme")
        check("provision acme → 204", r.status == 204, f"got {r.status} {r.body!r}")
        r = c.provision("wb")
        check("provision wb → 204", r.status == 204, f"got {r.status} {r.body!r}")
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

        print("step 2: worker booted with the tenant door enabled")
        check("boot log: 'tenant door enabled'",
              "tenant door enabled" in worker_log.read_text())

        print("step 3: wait for both deployments to load")
        ready = c.wait_for_handler("acme", "/?fn=handler", want_body="acme-ready")
        check("acme loaded", ready.status == 200 and "acme-ready" in ready.body,
              f"got {ready.status} {ready.body!r}")
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
        check("wb reachable; echoes echoed:<tag>", wb_ok,
              f"got {w.status if w else '-'} {w.body if w else '-'!r}")
        if not (ready.status == 200 and wb_ok):
            c.dump_node_log(grep=["deploy", "loader", "manifest", "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print("step 4: fire http.send at wb's TENANT HOSTNAME (door-matched)")
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
            c.dump_node_log(grep=["tenant door", "send", "fetch", "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print("step 5: delivery round-tripped through the pinned internal path")
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
        check("http/result/{id} row present", record is not None)
        if record:
            check("callback ok == true", record.get("ok") is True, f"got {record!r}")
            check("callback status == 200", record.get("status") == 200, f"got {record!r}")
            check(f"callback body == 'echoed:{TAG}'",
                  record.get("body") == f"echoed:{TAG}", f"got {record.get('body')!r}")

        print("step 6: the door fired exactly once, for the wb host")
        log_text = worker_log.read_text()
        door_lines = [l for l in log_text.splitlines() if "tenant door — outbound" in l]
        check("exactly one door pin line", len(door_lines) == 1,
              f"got {len(door_lines)}: {door_lines!r}")
        if door_lines:
            check("door line names the wb tenant host",
                  f"wb.{PUBLIC_SUFFIX}" in door_lines[0], door_lines[0])

        if failures:
            c.dump_node_log(grep=["tenant door", "send", "fetch", "error", "warn"])

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS — tenant door: inter-tenant http.send pinned to the internal front, "
          "delivered via Host routing, public DNS untouched.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
