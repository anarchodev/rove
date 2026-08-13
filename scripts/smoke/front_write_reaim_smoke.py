#!/usr/bin/env python3
"""Front-door write re-aim gate (originated as the rove#353 repro): a
body-carrying WRITE through the front door must survive a leader kill.

Provisions a tenant, warms the front's leader cache, then KILLS the leader so
leadership moves and the cache goes stale — the production condition, since a
rolling restart does exactly that. Then it hammers a body-carrying POST and
requires: nothing but 200s and (rare) honest ambiguous 502s, and — the
load-bearing invariant — a kv counter that moved exactly once per confirmed
write, so no request was ever silently double-executed (rove#532).

The invariants this guards (rove#353 + rove#532):

  * `handle421` aims the retry at the leader named by the `x-rewind-leader`
    hint — not at `node_idx + 1`, which lands on another follower (another
    421 → 503) or a downed node (dead leg → unretryable 502).
  * A forward whose request head provably never reached the peer (never
    serialized, its covering socket write failed, or the peer REFUSED_STREAM'd
    it) is retryable even for a non-idempotent write — nothing was delivered.
    Only a head that may be on the wire is ambiguous, and ambiguity goes to
    the client as a 502 for EVERY method (decisions.md §10.5d): a request
    racing the kill onto a half-closed socket can land in the dead peer's
    kernel buffer, and no userspace signal can prove it wasn't read.

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
export function get() {
  return { n: parseInt(kv.get("n") || "0", 10) || 0 };
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

        rr = c.request(TENANT, "/?fn=get")
        n0 = int(json.loads(rr.body)["n"]) if rr.status == 200 else 0

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
        # The failure shapes, post-rove#532:
        #   * anything that is neither a 200 nor an ambiguous 502 is a re-aim
        #     regression (rove#353's original bug class);
        #   * ambiguous 502s must stay RARE — a request racing the kill onto a
        #     half-closed socket is genuinely wire-ambiguous and the honest
        #     answer is a 502 the client may retry, but the COMMON path is the
        #     421 re-aim / failed-write replay, both silent;
        #   * and the load-bearing invariant: NO SILENT DOUBLE-EXECUTION. Every
        #     200 executed exactly once; a 502'd write executed at most once.
        #     The counter bounds both directions — a silently replayed request
        #     pushes the count past the ceiling (the rove#532 duplicate shape).
        bad = {k: v for k, v in codes.items() if k not in (200, 502)}
        check("stale-cache writes: only 200s or honest ambiguous 502s", not bad,
              f"unexpected statuses: {bad} of {ATTEMPTS}")
        amb = codes.get(502, 0)
        check("ambiguous 502s are the exception, not the path", amb <= 3,
              f"{amb} of {ATTEMPTS} — the re-aim machinery is not doing its job")
        ok_total = warm.get(200, 0) + codes.get(200, 0)
        rr = c.request_retry(TENANT, "/?fn=get", deadline_s=20.0)
        n_final = int(json.loads(rr.body)["n"]) if rr.status == 200 else -1
        delta = n_final - n0
        check("no silent double-execution (counter bounded by outcomes)",
              ok_total <= delta <= ok_total + amb,
              f"counter moved {delta} for {ok_total} confirmed + {amb} ambiguous writes")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print(f"\nPASS — {ATTEMPTS * 2} writes through the front: every 200 executed exactly once")
    return 0


if __name__ == "__main__":
    sys.exit(main())
