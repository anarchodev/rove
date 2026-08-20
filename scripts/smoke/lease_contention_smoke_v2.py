#!/usr/bin/env python3
"""Does the contended-lease skip actually run, and is it harmless when it does?

`dispatchOnce` opens a tenant's `TrackedTxn` EAGERLY, at anchor selection,
specifically so that per-tenant lock contention surfaces as `KvError.Conflict`
there rather than mid-handler. The loser marks the tenant in a tick-local
32-slot `BlockedTenants` list and goes on to serve a different tenant this
tick; the marked tenant is a candidate again on the next one.

That arm is structurally unreachable at one worker per process — no peer worker
can hold the lease — so it went unexecuted from the V1→V2 cutover until
`REWIND_WORKERS` came back (rove#679, #680). This smoke is the thing that
reaches it: several workers, one hot tenant, real connections hashed across
them by `SO_REUSEPORT`.

It asserts the observable contract, not the mechanism:

  1. the arm EXECUTES — `dispatch_lease_conflicts_total` moves. A run where it
     stays zero FAILS: everything below would pass just as happily on a node
     that never contended, which is exactly the state #680 was filed about.
  2. a contended request is never an error — no 500, no stall, no dropped
     request. Every one of them answers 200.
  3. losing the lease does not idle a worker: a second tenant is served
     throughout the storm.
  4. nothing starves. Every hot request completes, so a tenant marked blocked
     is picked again on a later tick rather than skipped for good.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import concurrent.futures
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

# Several workers, or there is no sibling to lose the lease to. Set before
# `spawn` so the node inherits it, and unconditionally, so an ambient
# `REWIND_WORKERS=1` cannot quietly turn this smoke into a no-op.
os.environ["REWIND_WORKERS"] = "4"

from smoke_lib_v2 import V2Cluster, _curl  # noqa: E402

# A handler that writes, so the request takes the anchor lease at all, and
# writes a few times, so the window a sibling worker can collide with is real
# work rather than a microsecond. NOT a busy loop: the per-handler CPU budget
# boxes the tenant well under a millisecond of spinning, and a boxed tenant
# 503s every request, which would prove nothing about the lease.
SRC = """
export default function () {
  kv.set("last", request.path);
  response.status = 200;
  return "served";
}
"""

HOT = "hot"
COOL = "cool"
# Enough concurrent connections that the kernel spreads them over all four
# workers; small enough to stay polite inside a parallel suite run.
HOT_CONNS = 24
COOL_CONNS = 6
ROUNDS = 6


def counter(text: str, name: str) -> int | None:
    """Read a bare Prometheus counter out of `/_system/metrics`."""
    for line in text.splitlines():
        if line.startswith(name + " "):
            try:
                return int(float(line.split(" ", 1)[1]))
            except ValueError:
                return None
    return None


def storm(c: V2Cluster) -> tuple[list[int], list[int]]:
    """One round: hammer HOT while COOL keeps asking, all direct-to-node so
    each request is its own connection and the kernel — not the front door's
    handful of pooled legs — decides which worker serves it."""
    def one(tenant: str) -> int:
        # Status 0 means "never answered". A tenant that is skipped and
        # never re-picked produces exactly that: the request sits in
        # `request_out` being re-walked forever while the worker idles, so
        # the client waits out its whole timeout. Short deadline on purpose
        # — a starved run should fail in seconds, not hang the suite.
        try:
            return _curl(f"{c.node_url(0)}/", host=c.host_for(tenant),
                         timeout=20.0).status
        except Exception:
            return 0

    with concurrent.futures.ThreadPoolExecutor(HOT_CONNS + COOL_CONNS) as pool:
        hot = [pool.submit(one, HOT) for _ in range(HOT_CONNS)]
        cool = [pool.submit(one, COOL) for _ in range(COOL_CONNS)]
        return ([f.result() for f in hot], [f.result() for f in cool])


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    print("=== the contended-lease skip, executed (rove#680) ===")

    with V2Cluster.spawn("leasecontend", nodes=1) as c:
        for t in (HOT, COOL):
            r = c.provision(t)
            check(f"provision {t} → 200", r.status == 200, f"got {r.status} {r.body!r}")
            c.deploy_handlers(t, {"index.mjs": SRC})
        for t in (HOT, COOL):
            r = c.wait_for_handler(t, "/", want_status=200)
            check(f"{t} serves before the storm", r.status == 200,
                  f"got {r.status} {r.body!r}")

        before = counter(c.metrics(), "dispatch_lease_conflicts_total")
        check("the node publishes dispatch_lease_conflicts_total",
              before is not None, f"reads {before}")
        base = before or 0

        hot_bad: list[int] = []
        cool_bad: list[int] = []
        hot_total = 0
        conflicts = 0
        for rnd in range(ROUNDS):
            hot, cool = storm(c)
            hot_total += len(hot)
            hot_bad += [s for s in hot if s != 200]
            cool_bad += [s for s in cool if s != 200]
            now = counter(c.metrics(), "dispatch_lease_conflicts_total")
            conflicts = (now or 0) - base
            print(f"    round {rnd + 1}: lease conflicts so far={conflicts} "
                  f"hot_non200={len(hot_bad)} cool_non200={len(cool_bad)}")
            if conflicts > 0 and rnd >= 1:
                break

        # (1) The negative control. Without this the three checks below are
        # assertions about a node that never contended.
        check("the contended-lease arm executed", conflicts > 0,
              f"dispatch_lease_conflicts_total +{conflicts} across {hot_total} "
              f"concurrent requests to one tenant")

        # (2) A lost lease is a skip, not an error. `Conflict` at anchor
        # selection must never reach the client.
        check("no contended request failed", not hot_bad,
              f"{len(hot_bad)} of {hot_total} non-200: {sorted(set(hot_bad))}")

        # (3) The whole point of the skip: the loser serves someone else
        # rather than idling behind a busy tenant.
        check("a second tenant was served throughout the storm", not cool_bad,
              f"{len(cool_bad)} non-200: {sorted(set(cool_bad))}")

        # (4) Tick-local: a blocked tenant is a candidate again on the next
        # tick. A tenant marked busy and never re-picked is a silent
        # starvation bug — the worker idles while the request is re-walked
        # and re-skipped forever — and it surfaces here as a request that
        # never answers at all.
        never = [s for s in (hot_bad + cool_bad) if s == 0]
        check("no request went unanswered", not never,
              f"{len(never)} request(s) never answered — a tenant marked busy "
              f"is not being re-picked on a later tick")

        # Informational, and a real signal if it ever moves: a tick that
        # stops on a full 32-slot list defers work rather than dropping it,
        # but a standing non-zero count means the cap is setting the pace.
        overflow = counter(c.metrics(), "dispatch_blocked_overflows_total")
        print(f"    dispatch_blocked_overflows_total={overflow}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\n✅ the contended-lease skip ran, cost nothing, and starved nobody")
    return 0


if __name__ == "__main__":
    sys.exit(main())
