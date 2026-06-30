#!/usr/bin/env python3
"""V2 port of `on_kv_smoke.py` — `on.kv` connection wakes (handler-surface
Phase 1 Task 3, kv half) on the `V2Cluster` harness.

The `onkv` handler reads `<prefix>flag` (baselining the §8.4 read_version
AFTER the read), arms `on.kv(prefix)`, and HOLDS the socket via `next()`
with NO webhook.send — so the ONLY thing that can resume the parked
continuation is a kv write under the watched prefix landing at a
write_version strictly greater than the baseline.

  client A ──POST /onkv {prefix}──▶ acme inbound hop          (HELD)
     kv.get(prefix+flag) + on.kv(prefix) + return next(...onWake)
        → StreamWakes{read_version, kv_prefixes} on the held continuation
        → entity parks in worker.parked_continuations (no response yet)

  ...~0.5s later...

  client B ──POST /writekv {key:prefix+flag,value}──▶ 204     (the trigger)
     leader commit arm → broadcastKvWake(write_version)
        → matchEventsToWakes: write_version > read_version → pending_wakes
        → sweepParkedContinuations (kv-due) → resumeContinuation(wake)
        → onWake re-reads kv → terminal → resolveParked

  client A ◀── 200 "woke:<value>"   (resumed by the kv write, ~0.5s)

Timing proves the path: the held POST must return SHORTLY AFTER the write
(not instantly — that would mean it never held; not at ~25s — that's the
§6.4 deadline, meaning the wake never fired). Single node/worker so the
park + the leader's commit-arm broadcast + the sweep are all the same
worker (cross-worker wake routing is orthogonal).

Dropped from V1 (V2-irrelevant): TLS/https, leader-direct addressing /
discover_leader, seed_manifest (V2 provisions+deploys explicitly).

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import concurrent.futures
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap  # noqa: E402

PREFIX = "onkv/"
WRITE_DELAY_S = 0.5

# Handlers verbatim from the V1 demo tenant
# (examples/loop46-demo-tenants/acme/{onkv,writekv}/index.mjs), with
# `__rove_next` already spelled `next()` (the V1 handler used `next()` too).
ONKV_SRC = """\
export default function () {
    const req = request.body ? JSON.parse(request.body) : {};
    const prefix = req.prefix || "onkv/";
    kv.get(prefix + "flag");
    on.kv(prefix, { to: "onWake" });
    return next({ prefix });
}

export function onWake() {
    const ctx = request.ctx || {};
    const v = kv.get(ctx.prefix + "flag");
    return "woke:" + (v ?? "none");
}
"""

WRITEKV_SRC = """\
export default function () {
    const body = JSON.parse(request.body || "{}");
    if (!body.key || typeof body.key !== "string") {
        response.status = 400;
        return "missing key";
    }
    kv.set(body.key, body.value ?? "");
    response.status = 204;
    return "";
}
"""

# A trivial root route for the readiness probe (the onkv/writekv routes
# either hold or mutate — neither is a clean GET probe).
READY_SRC = 'export function handler() { return "ready"; }\n'


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("on-kv", nodes=1) as c:
        print("step 1: provision tenant 'acme' via the CP")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 2: deploy onkv + writekv (+ a root readiness probe)")
        try:
            dep_id = c.deploy_handlers("acme", {
                "index.mjs": rpc_wrap(READY_SRC),
                "onkv/index.mjs": ONKV_SRC,
                "writekv/index.mjs": WRITEKV_SRC,
            })
            check("deploy_handlers → dep_id", bool(dep_id), f"dep_id={dep_id}")
        except RuntimeError as e:
            check("deploy_handlers", False, str(e))
            dep_id = None

        if not dep_id:
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print("step 3: wait for the deployment to load (GET / → 'ready')")
        ready = c.wait_for_handler("acme", "/?fn=handler", want_body="ready")
        check("deployment loaded", ready.status == 200 and "ready" in ready.body,
              f"got {ready.status} {ready.body!r}")
        if ready.status != 200:
            c.dump_node_log(grep=["deploy", "loader", "manifest", "resolve",
                                  "404", "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print("step 4: held POST /onkv, then a trigger write ~0.5s later")

        # THE held request: one blocking POST resumed by a kv write that a
        # SECOND request makes ~WRITE_DELAY_S later. Run the held POST on a
        # background thread so the main thread can fire the trigger write.
        def held() -> tuple[int, str, float]:
            t0 = time.monotonic()
            r = c.request("acme", "/onkv", method="POST",
                          headers={"content-type": "application/json"},
                          data=json.dumps({"prefix": PREFIX}),
                          timeout=30.0)  # > 25s §6.4 deadline so a 504 still returns
            return r.status, r.body, time.monotonic() - t0

        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            fut = pool.submit(held)
            # Let the inbound hop park the continuation before we write.
            time.sleep(WRITE_DELAY_S)
            # Fire the trigger write DIRECT to the node (not the front door):
            # the front door multiplexes a tenant's requests onto one upstream
            # h2 connection, so a trigger sent through it would queue behind the
            # still-open held stream (head-of-line) and only reach the worker
            # when the held curl gives up. The on.kv wake path is single-node;
            # hitting the node directly isolates the primitive under test.
            w = c.node_request("/writekv", method="POST", host=c.host_for("acme"),
                               headers={"content-type": "application/json"},
                               data=json.dumps({"key": PREFIX + "flag", "value": "hello"}))
            check("trigger writekv → 204", w.status == 204, f"got {w.status} {w.body!r}")

            status, body, elapsed = fut.result(timeout=35.0)

        check("on.kv → 200", status == 200, f"got {status} {body!r} ({elapsed:.2f}s)")
        check("on.kv body == 'woke:hello'", body == "woke:hello",
              f"got {body!r} ({elapsed:.2f}s)")
        if status != 200:
            c.dump_node_log(grep=["deploy", "loader", "manifest", "resolve",
                                  "404", "error", "warn", "kv", "wake", "park"])
        # Held until the write, then resumed: not instant (it would have had
        # to ignore the hold), not the deadline (the wake never fired).
        check("on.kv held for the write (not instant)", elapsed >= WRITE_DELAY_S * 0.5,
              f"returned in {elapsed:.3f}s — too fast; continuation didn't hold")
        check("on.kv not deadline-504 path", elapsed < 15.0,
              f"returned correct body but in {elapsed:.1f}s — that's the §6.4 deadline")
        if status == 200 and body == "woke:hello":
            print(f"  ok  on.kv wake resumed: held POST → '{body}' in {elapsed:.3f}s "
                  f"(woke ~{WRITE_DELAY_S}s after the write, not instant, not deadline)")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS on.kv smoke (v2)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
