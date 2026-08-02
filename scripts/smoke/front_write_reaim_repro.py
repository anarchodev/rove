#!/usr/bin/env python3
"""rove#353 repro + gate: a body-carrying WRITE through the front door can fail
with 502 `write-ambiguous` when the front must re-aim off a 421.

NOT wired into any suite — it is a standalone investigation tool, and it is
EXPECTED to fail until the residual below is fixed. Keeping it out of the suites
is deliberate: a flaky-red gate trains you to re-run instead of read.

## What it does

Provisions a tenant, warms the front's leader cache, then KILLS the leader so
leadership moves and the cache goes stale — the production condition, since a
rolling restart does exactly that. Then it hammers a body-carrying POST and
reports the status distribution.

A warm cache gives a clean 24/24; only the stale-cache burst fails. That is what
identifies the trigger as the re-aim path rather than writes in general.

## Fixed by this branch

`handle421` learned the leader from the `x-rewind-leader` hint, cached it for
FUTURE requests, and then re-aimed THIS one at `node_idx + 1` — another
follower (another 421, ultimately a 503 once the list ran out) or a node that
was down (a dead leg → an unretryable 502). It now aims at the hinted leader.
That takes the failure rate from roughly 2-in-3 bursts to about 1-in-5.

## Residual (still open)

```
forward … failed (conn_died=true, replayable=true, saw_421=true,
                  body=75B, idempotent=false)
```

The front re-aims at the correct leader and the POOLED connection to it is
already dead. The body is buffered and replayable and the 421 proved nothing
entered the log at the first node — but `attemptFailed` is called with
`head_sent` hardcoded `true`, so a non-idempotent flow can never be retried and
the client gets a 502 for a write no node accepted.

nginx draws this line differently: a failure at CONNECT time (nothing was sent)
is retried even for a POST, and only a failure AFTER the request went out is
treated as ambiguous. Closing this means the h2 client layer reporting whether
the head was actually written to a live socket, so the stale-pooled-leg case
becomes `head_sent = false` and retries safely.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, _curl, rpc_wrap  # noqa: E402

TENANT = "writer"
# A real WRITE: the 421 not-leader refusal is what a write earns on a follower,
# and it is the 421 → re-aim path that this is about.
SRC = """
export function put() {
  const n = (parseInt(kv.get("n") || "0", 10) || 0) + 1;
  kv.set("n", String(n));
  return { n: n };
}
"""
ATTEMPTS = 24


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("frontwrite", nodes=3) as c:
        print("step 1: provision + deploy a tenant with a write handler")
        r = c.provision(TENANT)
        check("provision → 200/409", r.status in (200, 409), f"got {r.status} {r.body!r}")
        dep = c.deploy_handlers(TENANT, {"index.mjs": rpc_wrap(SRC)})
        check("deploy → dep_id", bool(dep), f"dep_id={dep}")
        c.wait_for_handler(TENANT, "/?fn=put", want_status=200)

        print("step 2: which node leads this tenant (the front must re-aim to it)")
        leader = c.leader_now(TENANT)
        print(f"    leader node index: {leader} of {len(c.node_ports)} nodes")
        check("a leader exists", leader is not None, "no node self-reports leader")

        def burst(n: int) -> dict:
            out: dict[int, int] = {}
            for _ in range(n):
                rr = c.request(TENANT, "/?fn=put", method="POST",
                               data=json.dumps({"pad": "x" * 64}), timeout=20.0)
                out[rr.status] = out.get(rr.status, 0) + 1
            return dict(sorted(out.items()))

        print(f"step 3a: {ATTEMPTS} POSTs with a WARM leader cache")
        warm = burst(ATTEMPTS)
        print(f"    status distribution: {warm}")
        check("warm-cache writes all succeed", set(warm) == {200}, f"got {warm}")

        # The prod condition: a rolling restart moves leadership, so the front's
        # cached leader is stale and every write re-aims off a 421. That is the
        # path that failed in production, and a warm cache never exercises it.
        print(f"step 3b: kill the leader (node {leader}) → leadership moves, cache goes stale")
        c.kill_node(leader)
        new_leader = c.leader_node(TENANT, deadline_s=30.0)
        print(f"    new leader node index: {new_leader}")
        check("a new leader was elected", new_leader is not None, "none elected")

        print(f"step 3c: {ATTEMPTS} POSTs against the STALE cache (the repro)")
        codes = burst(ATTEMPTS)
        print(f"    status distribution: {codes}")

        print("step 4: what the front logged about the re-aims")
        c.dump_log("front", grep=["re-aim", "forward", "ambiguous", "no-leader"], tail=14)
        # The bug: any non-200 for a write the leader would have accepted.
        bad = {k: v for k, v in codes.items() if k != 200}
        check("every write through the front succeeded", not bad,
              f"reproduced #353: {bad} of {ATTEMPTS}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print(f"\nPASS — {ATTEMPTS}/{ATTEMPTS} body-carrying writes through the front succeeded")
    return 0


if __name__ == "__main__":
    sys.exit(main())
