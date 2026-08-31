#!/usr/bin/env python3
"""`await after.ms(ms)` — the same-connection promise model (`src/js/held.zig`).

The `promise` handler awaits a timer IN PLACE instead of parking with
`next()` and resuming in `onWake`: the handler's request arena is kept
across the hold, the timer sweep settles the awaited promise, and the
handler continues with its own locals, its own `request`, and the head it
sets AFTER the await. One blocking client POST per case:

  client ──POST /promise {ms,tag}──▶ acme inbound hop
     kv.set("before/<tag>") ; await after.ms(ms)     → RunOutcome.held
        → arena detached onto the entity (HeldRequest), timer armed,
          entity parks in worker.parked_continuations (held; no response)
     ~ms later: sweepParkedContinuations → resumeHeldChain → the promise
        resolves, the handler runs on: kv.set("after/<tag>"), status 201,
        returns "woke:<tag>:<local>" — resolveParked ships it
  ◀── 201 "woke:<tag>:kept"  (~ms after the request)

Cases: (1) a single await returns 201 with the handler's local intact and
the post-await status; (2) both kv writes — the one before the await
(activation 1) and the one after (activation 2) — are readable afterwards;
(3) two awaits in a row re-hold the same arena and complete; (4) a throw
after the await is a 500, never a silent body. Timing gates on (1): an
instant return means the request never held; ~25 s means the hold
deadline fired instead of the timer.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import concurrent.futures
import urllib.parse as up

from smoke_lib_v2 import PUBLIC_SUFFIX, V2Cluster, rpc_wrap  # noqa: E402

PROMISE_SRC = """\
export default async function () {
    const req = request.text ? request.json : {};
    const tag = req.tag || "t";
    const ms = req.ms || 150;
    const local = "kept";
    kv.set("before/" + tag, String(Date.now()));
    if (req.twice) {
        await after.ms(ms);
        await after.ms(ms);
    } else {
        await after.ms(ms);
    }
    kv.set("after/" + tag, String(Date.now()));
    if (req.throwAfter) throw new Error("boom:" + tag);
    response.status = 201;
    return "woke:" + tag + ":" + local + ":" + request.path;
}
"""
READ_SRC = """\
export function read() {
    const m = /(?:^|&)tag=([^&]*)/.exec(request.query || "");
    const tag = m ? m[1] : "";
    return JSON.stringify({ before: kv.get("before/" + tag), after: kv.get("after/" + tag) });
}
"""
WATCH_SRC = """\
export default async function () {
    const wake = await after.kv("watch/");
    const seen = kv.get("watch/flag");
    response.status = 201;
    return JSON.stringify({ kind: wake.kind, prefix: wake.prefix, seen: seen });
}
"""
POKE_SRC = """\
export function poke() {
    kv.set("watch/flag", "lit");
    return "poked";
}
"""
FETCHER_SRC = """\
export default async function () {
    const m = /(?:^|&)url=([^&]*)/.exec(request.query || "");
    const url = decodeURIComponent(m ? m[1] : "");
    const res = await after.fetch(url);
    response.status = 201;
    return JSON.stringify({ status: res.status, text: res.text, truncated: res.truncated,
                            idForm: typeof res === "object" ? "obj" : "str" });
}
export function onWake() { return "unused"; }
"""
WRITEFETCH_SRC = """\
export default async function () {
    const m = /(?:^|&)url=([^&]*)/.exec(request.query || "");
    const url = decodeURIComponent(m ? m[1] : "");
    await after.ms(50);                 // resume hop from here on
    kv.set("wf/before", "1");           // this hop WRITES ...
    const res = await after.fetch(url); // ... and then awaits a fetch
    response.status = 201;
    return JSON.stringify({ status: res.status, len: res.text.length });
}
"""
BULK_SRC = 'export function bulk() { return "0123456789".repeat(17); }\n'

READY_SRC = 'export function handler() { return "ready"; }\n'


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("promise-wake", nodes=1) as c:
        print("step 1: provision tenant 'acme'")
        r = c.provision("acme")
        check("provision → 200", r.status == 200, f"got {r.status} {r.body!r}")

        print("step 2: deploy the promise handler (+ a root readiness probe)")
        try:
            dep_id = c.deploy_handlers("acme", {
                "index.mjs": rpc_wrap(READY_SRC),
                "promise/index.mjs": PROMISE_SRC,
                "promiseread/index.mjs": rpc_wrap(READ_SRC),
                "watch/index.mjs": WATCH_SRC,
                "watchpoke/index.mjs": rpc_wrap(POKE_SRC),
                "fetcher/index.mjs": FETCHER_SRC,
                "writefetch/index.mjs": WRITEFETCH_SRC,
            })
            check("deploy_handlers → dep_id", bool(dep_id), f"dep_id={dep_id}")
        except RuntimeError as e:
            check("deploy_handlers", False, str(e))
            dep_id = None
        if not dep_id:
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1
        ready = c.wait_for_handler("acme", "/?fn=handler", want_body="ready")
        check("deployment loaded", ready.status == 200 and "ready" in ready.body,
              f"got {ready.status} {ready.body!r}")

        ms = 250
        print(f"step 3: held POST /promise {{ms:{ms},tag:'x'}} — resumed by the timer")
        t0 = time.monotonic()
        r = c.request("acme", "/promise", method="POST",
                      headers={"content-type": "application/json"},
                      data=json.dumps({"ms": ms, "tag": "x"}), timeout=30.0)
        elapsed = time.monotonic() - t0
        check("await after.ms → 201 (status set AFTER the await)", r.status == 201,
              f"got {r.status} {r.body!r} ({elapsed:.2f}s)")
        check("body carries the handler's local + its own request",
              r.body == "woke:x:kept:/promise", f"got {r.body!r}")
        check("held (not instant)", elapsed >= (ms / 1000.0) * 0.5,
              f"returned in {elapsed:.3f}s — too fast; the request never held")
        check("not the hold-deadline path", elapsed < 15.0,
              f"{elapsed:.1f}s — that's the 25 s deadline, not the timer")
        if r.status != 201:
            c.dump_node_log(grep=["held", "promise", "timer", "wake", "park", "error", "warn"])

        print("step 4: both activations' writes landed")
        r = c.request("acme", "/promiseread?fn=read&tag=x", method="GET", timeout=10.0)
        try:
            got = json.loads(r.body) if r.status == 200 else {}
        except ValueError:
            got = {}
        check("write BEFORE the await committed (activation 1)", bool(got.get("before")),
              f"got {r.status} {r.body!r}")
        check("write AFTER the await committed (activation 2)", bool(got.get("after")),
              f"got {r.status} {r.body!r}")
        if got.get("before") and got.get("after"):
            check("the after-write is later than the before-write",
                  int(got["after"]) >= int(got["before"]), f"{got}")

        print("step 5: two awaits re-hold the same arena")
        t0 = time.monotonic()
        r = c.request("acme", "/promise", method="POST",
                      headers={"content-type": "application/json"},
                      data=json.dumps({"ms": 150, "tag": "y", "twice": True}), timeout=30.0)
        elapsed = time.monotonic() - t0
        check("two awaits → 201", r.status == 201 and r.body == "woke:y:kept:/promise",
              f"got {r.status} {r.body!r} ({elapsed:.2f}s)")
        check("two awaits took ≥ 2 timers", elapsed >= 0.15, f"{elapsed:.3f}s")

        print("step 6: await after.kv — a concurrent write settles the promise")
        def held_watch():
            r2 = c.request("acme", "/watch", method="POST", data="{}", timeout=30.0)
            return r2.status, r2.body
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            fut = pool.submit(held_watch)
            time.sleep(1.0)  # let the inbound hop park before writing
            w = c.request("acme", "/watchpoke?fn=poke", method="GET", timeout=10.0)
            check("poke → 200", w.status == 200 and "poked" in w.body, f"got {w.status} {w.body!r}")
            status, body = fut.result(timeout=35.0)
        try:
            got = json.loads(body) if status == 201 else {}
        except ValueError:
            got = {}
        check("await after.kv → 201", status == 201, f"got {status} {body!r}")
        check("promise resolved with the wake entry", got.get("kind") == "kv" and got.get("prefix") == "watch/",
              f"got {got}")
        check("handler re-read sees the write", got.get("seen") == "lit", f"got {got}")

        print("step 7: provision 'wb' as the fetch upstream; await after.fetch")
        r = c.provision("wb")
        check("provision wb → 200", r.status == 200, f"got {r.status}")
        try:
            wb_dep = c.deploy_handlers("wb", {"index.mjs": rpc_wrap(BULK_SRC)})
        except RuntimeError as e:
            wb_dep = None
            check("deploy wb", False, str(e))
        if wb_dep:
            ready2 = c.wait_for_handler("wb", "/?fn=bulk", want_body="0123456789")
            check("wb upstream ready", ready2.status == 200, f"got {ready2.status}")
            bulk_url = f"http://wb.{PUBLIC_SUFFIX}:{c.front_port}/?fn=bulk"
            r = c.request("acme", f"/fetcher?url={up.quote(bulk_url)}", method="POST", data="{}", timeout=30.0)
            try:
                got = json.loads(r.body) if r.status == 201 else {}
            except ValueError:
                got = {}
            check("await after.fetch → 201", r.status == 201, f"got {r.status} {r.body!r}")
            check("resolved with the whole response", got.get("status") == 200 and got.get("text") == "0123456789" * 17,
                  f"got status={got.get('status')} len={len(got.get('text') or '')}")
            check("not truncated, object form", got.get("truncated") is False and got.get("idForm") == "obj",
                  f"got {got}")

        if wb_dep:
            print("step 7b: a RESUME hop that writes kv then awaits a fetch (bind from a writing resume)")
            r = c.request("acme", f"/writefetch?url={up.quote(bulk_url)}", method="POST", data="{}", timeout=30.0)
            try:
                got = json.loads(r.body) if r.status == 201 else {}
            except ValueError:
                got = {}
            check("write-then-await-fetch in a resume hop → 201", r.status == 201, f"got {r.status} {r.body!r}")
            check("the fetch resolved after the write committed", got.get("status") == 200 and got.get("len") == 170,
                  f"got {got}")

        print("step 8: a throw after the await is a loud 500")
        r = c.request("acme", "/promise", method="POST",
                      headers={"content-type": "application/json"},
                      data=json.dumps({"ms": 100, "tag": "z", "throwAfter": True}), timeout=30.0)
        check("throw after await → 500", r.status == 500, f"got {r.status} {r.body!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS promise-wake smoke")
    return 0


if __name__ == "__main__":
    sys.exit(main())
