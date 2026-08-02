#!/usr/bin/env python3
"""Per-arm `{on}` wake exports — each armed `after.*` resumes into its OWN
export.

A held chain that arms `after.ms(..,{on:onTimeout})` + `after.kv(..,{on:onMsg})`
must route the timer fire to `onTimeout` and a kv fire to `onMsg`. Prod used
to fold both into ONE chain-level export (last-`{on}`-wins), so EVERY wake
dispatched the last-registered export (`onMsg`) — the timeout path never ran.
The sim already resolves each arm's own `{on}`; this makes prod match.

Buffered held chain (cont family — `resumeContinuation`), so the held GET
returns only when a terminal wake resolves it:

  GET /hold          → arms after.ms(1200,{on:onTimeout}) + after.kv("msg/r1/",
                       {on:onMsg}), seeds `room/r1/lastwake=none`, next()
  POST /poke (~0.5s) → kv.set("msg/r1/x") → the kv wake resumes `onMsg`, which
                       writes `room/r1/lastwake = onMsg:<fired prefix>` and
                       re-holds (no re-arm — the timer arm rides)
  timer fires (~1.2s)→ the timer wake resumes `onTimeout`, which returns a
                       TERMINAL 200 body `onTimeout:<lastwake>` → the held GET
                       resolves.

Assert the GET body is `onTimeout:onMsg:msg/r1/` — proving the timer ran
`onTimeout` (per-arm) AND the kv fire ran `onMsg` for its own prefix. Before
the fix the timer routes to `onMsg` too, `onTimeout` never runs, and the held
GET hangs to the ~25 s deadline (504) — the failing assertion.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import concurrent.futures
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap  # noqa: E402

ROOM = "r1"
PREFIX = f"msg/{ROOM}/"

HOLD_SRC = """\
export default function () {
    kv.set("room/r1/lastwake", "none");
    after.ms(1200, { on: "onTimeout" });   // timer arm → onTimeout
    after.kv("msg/r1/", { on: "onMsg" });  // kv arm → onMsg
    return next({ room: "r1" });           // buffered hold
}

// The kv arm's own export. Records which prefix fired, then re-holds
// WITHOUT re-arming — the timer arm rides untouched.
export function onMsg() {
    const w = request.activation.wakes;
    kv.set("room/r1/lastwake", "onMsg:" + ((w[0] && w[0].prefix) || "?"));
    return next({ room: "r1" });
}

// The timer arm's own export. Terminal — resolves the held GET. If per-arm
// routing is broken the timer routes here to onMsg instead and this never runs.
export function onTimeout() {
    response.status = 200;
    return "onTimeout:" + (kv.get("room/r1/lastwake") || "?");
}
"""

POKE_SRC = """\
export default function () {
    kv.set("msg/r1/x", "hello");   // fires the after.kv("msg/r1/") arm
    response.status = 204;
    return "";
}
"""

READY_SRC = 'export function handler() { return "ready"; }\n'


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("perarmwake", nodes=1) as c:
        r = c.provision("acme")
        check("provision → 200", r.status == 200, f"got {r.status} {r.body!r}")
        try:
            dep_id = c.deploy_handlers("acme", {
                "index.mjs": rpc_wrap(READY_SRC),
                "hold/index.mjs": HOLD_SRC,
                "poke/index.mjs": POKE_SRC,
            })
            check("deploy → dep_id", bool(dep_id), f"dep_id={dep_id}")
        except RuntimeError as e:
            check("deploy", False, str(e))
            print("\nFAILURES:", failures)
            return 1

        ready = c.wait_for_handler("acme", "/?fn=handler", want_body="ready", timeout_s=25.0)
        check("deployment loaded", ready.status == 200, f"got {ready.status} {ready.body!r}")
        if failures:
            c.dump_node_log(grep=["deploy", "loader", "manifest", "error", "warn"])
            print("\nFAILURES:", failures)
            return 1

        def held():
            return c.get("acme", "/hold", timeout=30.0)

        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            fut = pool.submit(held)
            time.sleep(0.5)  # let the inbound hop park + arm both wakes
            p = c.node_request("/poke", method="POST", host=c.host_for("acme"))
            check("poke → 204", p.status == 204, f"got {p.status} {p.body!r}")
            r = fut.result(timeout=35.0)

        # The core #142 assertions.
        check("held GET resolved via onTimeout → 200 (timer routed per-arm)",
              r.status == 200, f"got {r.status} {r.body!r}")
        check("timer ran onTimeout AND kv ran onMsg for its own prefix",
              r.body == f"onTimeout:onMsg:{PREFIX}",
              f"got {r.body!r} want 'onTimeout:onMsg:{PREFIX}'")
        if r.status != 200:
            c.dump_node_log(grep=["wake", "onMsg", "onTimeout", "park", "resume",
                                  "error", "warn"])

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS per-arm wake export smoke (v2): timer→onTimeout, kv→onMsg "
          "(each arm resumes its own {on}) — issue #142")
    return 0


if __name__ == "__main__":
    sys.exit(main())
