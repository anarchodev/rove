#!/usr/bin/env python3
"""Front-door write re-aim gate (originated as the rove#353 repro): a
body-carrying WRITE through the front door must survive a leader kill.

Provisions a tenant, warms the front's leader cache, then KILLS the leader so
leadership moves and the cache goes stale — the production condition, since a
rolling restart does exactly that. Then it hammers a body-carrying POST and
requires a clean status distribution: every write 2xx, zero 502
`write-ambiguous`.

The invariants this guards (both shipped for rove#353):

  * `handle421` aims the retry at the leader named by the `x-rewind-leader`
    hint — not at `node_idx + 1`, which lands on another follower (another
    421 → 503) or a downed node (dead leg → unretryable 502).
  * A forward that dies before the request head was written to a live socket
    (`head_sent = false` — e.g. a stale pooled leg to the new leader) is
    retryable even for a non-idempotent write: the 421 proved nothing entered
    the log, and nothing was sent on the dead leg. This is the nginx line —
    only a failure AFTER the head went out is ambiguous.

A warm cache passes trivially; only the stale-cache burst exercises the re-aim
path, which is why the kill sits between the warm-up and the burst.

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

        print(f"step 3c: {ATTEMPTS} POSTs against the STALE cache (the re-aim burst)")
        codes = burst(ATTEMPTS)
        print(f"    status distribution: {codes}")

        print("step 4: what the front logged about the re-aims")
        c.dump_log("front", grep=["re-aim", "forward", "ambiguous", "no-leader"], tail=14)
        # The failure shape: any non-200 for a write the leader would have
        # accepted (rove#353's 502 `write-ambiguous`).
        bad = {k: v for k, v in codes.items() if k != 200}
        check("every write through the front succeeded", not bad,
              f"non-200s: {bad} of {ATTEMPTS}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print(f"\nPASS — {ATTEMPTS}/{ATTEMPTS} body-carrying writes through the front succeeded")
    return 0


if __name__ == "__main__":
    sys.exit(main())
