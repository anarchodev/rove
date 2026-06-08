#!/usr/bin/env python3
"""Smoke for the per-tenant rate limiter — V2 port on the `V2Cluster`
harness (branch `v2`).

The per-tenant request bucket + email bucket (`src/js/limiter.zig`,
PLAN §2.10) are enforced in the V2 worker's dispatch path off each
tenant's resolved plan limits (docs/plan-tiers.md Lever 1) — there is no
`--rate-limit-*` worker flag anymore. So this port dials a tiny cap by
installing a plan blob through the worker's move-secret-gated
`/_system/v2-plan` surface (`c.set_plan`), the same single-target push
the CP uses on a live tier change. Installing a plan bumps `plan_gen`, so
the limiter re-snapshots the bucket to the new (tiny) cap on the next
request — letting the smoke warm the deploy at the default cap first,
then start the exhaustion test from a clean tiny bucket.

Asserts (the essential V1 coverage; TLS / 3-node / OIDC-admin dropped):
  1. rl1's request bucket exhausts at its cap → next request 429 with a
     Retry-After header + an explanatory body.
  2. rl2 is independent — unaffected by rl1's exhaustion (per-instance
     buckets).
  3. The email bucket throws a CATCHABLE `Error{code:"rate_limited"}`
     once its (tiny) cap is exhausted.

Handler JS reused verbatim from the V1 original. `request_refill_per_sec`
/ `email_refill_per_sec` are pinned to 0 so the bucket never refills
mid-test (deterministic exhaustion).

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

# Per-instance request-bucket capacity for the exhaustion test. Small +
# refill-0 so REQ_CAP 200s then one 429 is deterministic.
REQ_CAP = 8

# Trivial 200 handler (verbatim from the V1 smoke).
INDEX_SRC = 'export default function () { return { ok: true }; }'

# Email handler (verbatim from the V1 smoke) — catches the rate_limited
# Error the email bucket throws and returns its code/message.
EMAIL_SRC = '''export default function () {
  try {
    email.send({
      key: "re_test",
      from: "test@example.com",
      to: "user@example.com",
      subject: "hi",
      text: "test",
    });
    return { ok: true };
  } catch (e) {
    return { ok: false, code: e.code, message: e.message };
  }
}'''


def _plan_blob(*, request_capacity: int, email_capacity: int) -> str:
    """A free-tier plan with overrides dialing tiny, refill-0 caps."""
    return json.dumps({
        "tier": "free",
        "overrides": {
            "request_capacity": request_capacity,
            "request_refill_per_sec": 0,
            "email_capacity": email_capacity,
            "email_refill_per_sec": 0,
        },
    })


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("rate-limit", nodes=1) as c:
        print("step 1: provision + deploy rl1 + rl2 (trivial 200 handler)")
        for t in ("rl1", "rl2"):
            r = c.provision(t)
            check(f"provision {t} → 204", r.status == 204, f"got {r.status} {r.body!r}")
        try:
            c.deploy_handlers("rl1", {"index.mjs": INDEX_SRC})
            c.deploy_handlers("rl2", {"index.mjs": INDEX_SRC, "email/index.mjs": EMAIL_SRC})
            check("deploy rl1 + rl2", True)
        except RuntimeError as e:
            check("deploy rl1 + rl2", False, str(e))
            print("\nFAILURES:", failures)
            return 1

        print("step 2: wait for both deployments to load (default cap)")
        r1 = c.wait_for_handler("rl1", "/", want_body='"ok":true')
        check("rl1 loaded", r1.status == 200 and '"ok":true' in r1.body,
              f"got {r1.status} {r1.body!r}")
        r2 = c.wait_for_handler("rl2", "/", want_body='"ok":true')
        check("rl2 loaded", r2.status == 200 and '"ok":true' in r2.body,
              f"got {r2.status} {r2.body!r}")
        # Warm the email route too so its first real call isn't racing load.
        re_ = c.wait_for_handler("rl2", "/email", want_body='"ok":true')
        check("rl2 /email loaded", re_.status == 200,
              f"got {re_.status} {re_.body!r}")
        if failures:
            c.dump_node_log(grep=["deploy", "loader", "manifest", "resolve",
                                  "404", "error", "warn"])
            print("\nFAILURES:", failures)
            return 1

        print(f"step 3: dial tiny caps via /_system/v2-plan "
              f"(request_capacity={REQ_CAP}, email_capacity=2)")
        # Installing the plan bumps plan_gen → the limiter re-snapshots the
        # bucket to the new cap, full, on the next request. So the warm-up
        # 200s above don't count against the exhaustion budget.
        rp1 = c.set_plan("rl1", _plan_blob(request_capacity=REQ_CAP, email_capacity=2))
        check("set rl1 plan → 204", rp1.status == 204, f"got {rp1.status} {rp1.body!r}")
        rp2 = c.set_plan("rl2", _plan_blob(request_capacity=10_000, email_capacity=2))
        check("set rl2 plan → 204", rp2.status == 204, f"got {rp2.status} {rp2.body!r}")
        # Read-back proves delivery landed.
        gp = c.get_plan("rl1")
        eff = json.loads(gp.body) if gp.status == 200 else {}
        check("rl1 effective request_capacity == REQ_CAP",
              eff.get("request_capacity") == REQ_CAP, f"got {gp.body!r}")

        print(f"step 4: rl1 request bucket exhausts at {REQ_CAP} → 429")
        # Hit rl1 REQ_CAP times (within capacity).
        within = True
        for i in range(1, REQ_CAP + 1):
            r = c.get("rl1", "/")
            if r.status != 200:
                within = False
                check(f"request {i} (within capacity) → 200", False, f"got {r.status}")
                break
        if within:
            check(f"first {REQ_CAP} requests within capacity → 200", True)
        # Next one: bucket exhausted.
        r = c.get("rl1", "/")
        check(f"request {REQ_CAP + 1} → 429 (bucket exhausted)", r.status == 429,
              f"got {r.status}")
        check("Retry-After header present on 429", "retry-after" in r.headers,
              f"headers={list(r.headers)}")
        check("429 body explains the limit", "rate limit exceeded" in r.body,
              f"body={r.body!r}")

        print("step 5: rl2 independent of rl1's exhaustion")
        r = c.get("rl2", "/")
        check("rl2 not affected by rl1's exhaustion → 200", r.status == 200,
              f"got {r.status} {r.body!r}")

        print("step 6: email bucket → catchable rate_limited after 2")
        # email_capacity=2 → first 2 succeed, 3rd throws catchable rate_limited.
        for i in (1, 2):
            r = c.get("rl2", "/email")
            check(f"email.send {i} within capacity → ok:true",
                  '"ok":true' in r.body, f"got {r.status} {r.body!r}")
        r = c.get("rl2", "/email")
        check("email.send 3 → Error{code:'rate_limited'}",
              '"code":"rate_limited"' in r.body, f"got {r.status} {r.body!r}")
        check("email 429 message explains the limit",
              "email rate limit exceeded" in r.body, f"got {r.body!r}")

        if failures:
            c.dump_node_log(grep=["rate", "limit", "429", "plan", "email",
                                  "resolve", "404", "error", "warn"])

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS rate-limit smoke (v2): per-tenant request bucket trips 429 + "
          "Retry-After; sibling tenant unaffected; email bucket throws "
          "catchable rate_limited")
    return 0


if __name__ == "__main__":
    sys.exit(main())
