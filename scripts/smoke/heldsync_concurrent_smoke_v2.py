#!/usr/bin/env python3
"""Concurrent same-tenant heldsync smoke (V2 port) — regression guard for
the `cont_bound_sched_id` scan fix, on the `V2Cluster` harness (branch `v2`).

Pre-fix, the worker's scan over `writeset.ops.items` looked at the WHOLE
batch's writeset. When N concurrent same-tenant heldsync requests landed in
one per-tenant dispatch tick, each request's scan saw N `_send/owed/{id}`
puts and returned `null` ("ambiguous → null"). All N conts then deadlined
to a §6.4 504 because no `_send/owed/` binding was registered.

Post-fix the scan is scoped to ops THIS handler appended after its
per-handler savepoint, so each concurrent request sees only its own
`_send/owed/{id}` put → exactly one match → cont binds → resume fires.

V2 specifics (vs the V1 original):
  - Single node (nodes=1) — single worker, so all N concurrent requests
    pile into ONE per-tenant dispatch batch (the exact case the fix targets).
  - Plaintext h2c through the FRONT door; no TLS / leader-direct / 503.
  - Outbound webhook.send target is the `wb` echo tenant at its hostname:port
    (`http://wb.localhost:<node_port>/echo`) — V2 binds 0.0.0.0 + does not
    SSRF-block outbound, so no `--dev-webhook-unsafe`.

The held POSTs ride the front door (each terminates by the §6.4 deadline at
worst), and the resume is driven by the internal webhook completion (not a
second client request), so there is no front-door head-of-line concern.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import concurrent.futures
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, PUBLIC_SUFFIX, rpc_wrap  # noqa: E402

N_CONCURRENT = 20

# Handlers verbatim from the V1 demo tenant (heldsync open + onResult resume,
# wb echo) — same JS the heldsync_smoke_v2 template provisions.
HELDSYNC_SRC = r"""export default function () {
    const req = JSON.parse(request.body);
    const opts = {
        url: req.target,
        method: "POST",
        body: JSON.stringify({ from: "heldsync", tag: req.tag }),
        headers: { "content-type": "application/json" },
        max_attempts: 1,
    };
    webhook.send(opts);
    return __rove_next("heldsync/onresult", {
        fn: "onResult",
        ctx: { tag: req.tag, tries: 0, retry_to: req.retry_to || null },
    });
}
"""

ONRESULT_SRC = r"""export function onResult() {
    // Endpoint A: ctx IS request.ctx; result flattened on request.*.
    const ctx = request.ctx || {};
    if (!request.ok) {
        response.status = 502;
        return "heldsync upstream failed: " + (request.activation.error || request.status);
    }
    return "heldsync:" + ctx.tag + ":" + request.body;
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


def one_request(c: V2Cluster, wb_url: str, i: int) -> tuple[int, str, float]:
    t0 = time.monotonic()
    try:
        r = c.request(
            "acme", "/heldsync", method="POST",
            headers={"content-type": "application/json"},
            data=json.dumps({"target": wb_url, "tag": f"v{i}"}),
            timeout=30.0,
        )
    except Exception as e:
        return (i, f"request raised: {e}", time.monotonic() - t0)
    elapsed = time.monotonic() - t0
    if r.status != 200:
        return (i, f"status={r.status} body={r.body[:200]!r}", elapsed)
    want = f"heldsync:v{i}:echoed:v{i}"
    if r.body != want:
        return (i, f"body={r.body!r} want={want!r}", elapsed)
    if elapsed >= 15.0:
        return (i, f"took {elapsed:.1f}s — hit §6.4 deadline (scan-fix regressed)", elapsed)
    return (i, "", elapsed)


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("heldsync-concurrent", nodes=1) as c:
        print("step 1: provision tenants 'acme' + 'wb' via the CP")
        r = c.provision("acme")
        check("provision acme → 204", r.status == 204, f"got {r.status} {r.body!r}")
        r = c.provision("wb")
        check("provision wb → 204", r.status == 204, f"got {r.status} {r.body!r}")

        print("step 2: deploy wb (echo) + acme (heldsync open + resume hops)")
        try:
            c.deploy_handlers("wb", {"index.mjs": WB_SRC, "echo/index.mjs": WB_SRC})
            dep_id = c.deploy_handlers("acme", {
                "index.mjs": rpc_wrap(READY_SRC),
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
        wb_url = f"http://wb.{PUBLIC_SUFFIX}:{c.front_port}/echo"
        deadline = time.monotonic() + 25.0
        wb_ok = False
        w = None
        while time.monotonic() < deadline:
            w = c.node_request("/echo", method="POST", host=f"wb.{PUBLIC_SUFFIX}",
                               headers={"content-type": "application/json"},
                               data=json.dumps({"tag": "sanity"}))
            if w.status == 200 and w.body == "echoed:sanity":
                wb_ok = True
                break
            time.sleep(0.4)
        check("wb (third party) reachable; echoes", wb_ok,
              f"got {w.status if w else '-'} {w.body if w else '-'!r}")
        if not (ready.status == 200 and wb_ok):
            c.dump_node_log(grep=["deploy", "loader", "manifest", "resolve", "404",
                                  "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print("step 4: warm-up — one held-sync resumes")
        _, warmup_err, _ = one_request(c, wb_url, -1)
        check("warm-up held-sync resumed", not warmup_err, warmup_err)
        if warmup_err:
            c.dump_node_log(grep=["webhook", "send", "owed", "resume", "park",
                                  "held", "continuation", "next", "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print(f"step 5: THE concurrent burst — {N_CONCURRENT} held-syncs in parallel")
        t0 = time.monotonic()
        burst_failures: list[tuple[int, str, float]] = []
        elapsed_per: list[float] = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=N_CONCURRENT) as pool:
            futs = [pool.submit(one_request, c, wb_url, i) for i in range(N_CONCURRENT)]
            for f in concurrent.futures.as_completed(futs):
                i, err, el = f.result()
                elapsed_per.append(el)
                if err:
                    burst_failures.append((i, err, el))
        wall = time.monotonic() - t0

        if burst_failures:
            for i, err, el in sorted(burst_failures):
                print(f"    FAIL request {i} ({el:.2f}s): {err}")
            c.dump_node_log(grep=["webhook", "send", "owed", "resume", "park",
                                  "held", "continuation", "next", "error", "warn"])
        check(f"{N_CONCURRENT}/{N_CONCURRENT} concurrent held-syncs resumed (no cross-talk)",
              not burst_failures,
              f"{len(burst_failures)}/{N_CONCURRENT} failed — cont_bound_sched_id scan-fix regressed")
        if not burst_failures:
            slowest = max(elapsed_per)
            print(f"  ok  {N_CONCURRENT}/{N_CONCURRENT} resumed in {wall:.2f}s wall "
                  f"(slowest {slowest:.2f}s)")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS heldsync concurrent smoke (v2) — scan scoped to this "
          "request's writeset contribution, not the whole batch")
    return 0


if __name__ == "__main__":
    sys.exit(main())
