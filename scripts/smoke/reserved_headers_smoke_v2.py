#!/usr/bin/env python3
"""Reserved-header confused-deputy smoke — a client-supplied `x-rewind-*` /
`x-rove-internal-*` header at the edge buys nothing, in EITHER direction.

Why a smoke and not a unit test. Both halves of the reservation are already
unit-tested — `reserved_headers.zig` tests the predicate, `response_building`
tests the response gate — and neither test can see the thing that matters:
whether the predicate is actually CONSULTED on the path a request takes
through a real front door into a real handler. The predicate passing while
the installer skips it looks identical from a unit test.

The reservation is what lets internal endpoints treat these names as
theirs, and there is already a deputy that trusts one by NAME rather than
by value: the front's `leaderOriginHint` reads `x-rewind-leader` off a
response and retargets its leader-aware walk to whatever raft node id it
names. So leg C is not hypothetical — an emittable `x-rewind-leader` would
let a customer handler steer another tenant's routing.

Deliberately NOT asserted: that the front STRIPS these on the way in. It
does not, and that is the design (rove#836) — a reserved header carries
authority in its VALUE, never in its presence, so an ingress strip would
buy nothing and would imply a trust the verifier must not assume. What is
asserted is that nothing downstream trusts presence.

Legs:
  A. inbound — a client's `x-rewind-tenant` / `x-rewind-move-secret` /
     `x-rove-internal-*` are invisible in `request.headers`, while an
     ordinary header and the one customer-facing tracing header
     (`x-rove-correlation-id`) both arrive.
  B. privileged door — a client-chosen move secret at `/_system/*` is
     refused. Presence is not authority; the value is.
  C. outbound — a handler that tries to EMIT `x-rewind-leader` (and a
     reserved name under each prefix) does not get it onto the wire.

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap, _curl  # noqa: E402

# Every reserved name the client will try, plus the two that must survive.
SPOOFED = {
    "X-Rewind-Tenant": "__admin__",
    "X-Rewind-Move-Secret": "not-the-secret",
    "X-Rewind-Leader": "3",
    "X-Rove-Internal-Whatever": "1",
}
INNOCENT = {
    "X-App-Thing": "kept",
    # NOT reserved on purpose: the one intentionally customer-facing
    # tracing header (it seeds the saga id).
    "X-Rove-Correlation-Id": "corr-42",
}

SRC = (
    # Echo the header NAMES the handler can see, sorted, newline-joined.
    "export function seen() {\n"
    "  return Object.keys(request.headers).sort().join(',') + '\\n';\n"
    "}\n"
    # Try to emit reserved response headers alongside an ordinary one.
    # The response head is AMBIENT (`response.headers`, handler-shape.md) —
    # an object returned from the handler is just a body, so setting the
    # head any other way tests nothing.
    "export function emit() {\n"
    "  response.headers = {\n"
    "    'x-rewind-leader': '3',\n"
    "    'x-rewind-tenant': '__admin__',\n"
    "    'x-rove-internal-thing': '1',\n"
    "    'x-app-echo': 'ok',\n"
    "  };\n"
    "  return 'emitted\\n';\n"
    "}\n"
)


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("reservedhdr", nodes=1) as c:
        print("step 1: provision + deploy the echo handler")
        r = c.provision("acme")
        check("provision → 200", r.status == 200, f"got {r.status} {r.body!r}")
        dep_id = c.deploy_handlers("acme", {"index.mjs": rpc_wrap(SRC)})
        check("deploy_handlers → dep_id", bool(dep_id), f"dep_id={dep_id}")

        print("step 2 (leg A): the client's reserved headers are invisible to the handler")
        # Wait for the deployment to load (async after release), THEN fire the
        # spoofed request — `wait_for_handler` polls without extra headers.
        r = c.wait_for_handler("acme", "/?fn=seen", want_body="host")
        check("handler serving", r.status == 200, f"got {r.status} {r.body[:200]!r}")
        r = c.get("acme", "/?fn=seen", headers={**SPOOFED, **INNOCENT})
        check("GET /?fn=seen → 200", r.status == 200, f"got {r.status} {r.body[:200]!r}")
        seen = set(filter(None, r.body.strip().split(",")))
        for name in SPOOFED:
            check(f"handler cannot see {name}", name.lower() not in seen,
                  f"saw {sorted(seen)}")
        for name in INNOCENT:
            check(f"handler still sees {name}", name.lower() in seen,
                  f"saw {sorted(seen)}")

        print("step 3 (leg B): a client-chosen move secret is refused at /_system/*")
        r = _curl(f"{c.node_url(0)}/_system/v2-member-status?tenant=acme",
                  headers={"X-Rewind-Move-Secret": "not-the-secret"})
        check("/_system with a wrong move secret → 401/403",
              r.status in (401, 403), f"got {r.status} {r.body[:160]!r}")
        r = _curl(f"{c.node_url(0)}/_system/v2-member-status?tenant=acme")
        check("/_system with NO move secret → 401/403",
              r.status in (401, 403), f"got {r.status} {r.body[:160]!r}")

        print("step 4 (leg C): the handler cannot emit a reserved response header")
        r = c.get("acme", "/?fn=emit")
        check("GET /?fn=emit → 200", r.status == 200, f"got {r.status} {r.body[:200]!r}")
        got = {k.lower() for k in r.headers}
        for name in ("x-rewind-leader", "x-rewind-tenant", "x-rove-internal-thing"):
            check(f"handler cannot emit {name}", name not in got,
                  f"response headers {sorted(got)}")
        check("an ordinary response header still passes", "x-app-echo" in got,
              f"response headers {sorted(got)}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS reserved-headers smoke (v2)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
