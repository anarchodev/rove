#!/usr/bin/env python3
"""Does a real captured record carry an interaction digest, and does the digest
follow the handler's behaviour?

The digest (`src/tape/interaction_digest.zig`) is what makes "the handler
executed the same" checkable instead of assumed — without it, fidelity can only
mean "ended on the same status", which a handler can satisfy down a different
path. Unit tests cover the folding; this asserts the value survives the whole
capture path (worker → log batch → S3 → log server → the read API), because a
digest that is computed and then dropped somewhere in the middle is
indistinguishable from one that was never computed.

Three properties, each chosen to fail for a different reason:

  1. a logged request's record carries a non-null digest at all;
  2. two requests that do the SAME thing digest identically — the property a
     replay comparison depends on, and the one that breaks if anything
     per-request (a timestamp, a request id, a seed) leaks into the hash;
  3. a request that writes a DIFFERENT value digests differently even though
     its response is byte-identical — the case a status-only or response-only
     check misses entirely, which is the whole reason the digest exists.

Ports: 19820/19920 (see the per-smoke port table; do not run two smokes at
once). Needs S3 credentials: `set -a; . ./.env; set +a`.
"""
from __future__ import annotations

import json
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from smoke_lib_v2 import V2Cluster  # noqa: E402

# `mode` picks what the handler writes, so runs can be identical or not while
# the RESPONSE stays the same in both cases.
FIXTURE = {
    "index.mjs": """
export default function () {
  const seen = kv.get("counter") ?? "0";
  const mode = request.query && request.query.includes("mode=b") ? "b" : "a";
  kv.set("mark", mode === "b" ? "value-b" : "value-a");
  response.status = 200;
  return "same-body";
}
""",
}


def digest_of(records: list[dict], path_needle: str) -> str | None:
    for r in records:
        if path_needle in (r.get("path") or ""):
            return (r.get("tapes") or {}).get("interaction_digest")
    return None


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    print("=== interaction digest reaches the record (real worker + S3) ===")
    with V2Cluster.spawn("digest", nodes=1, http_base=19820, raft_base=19920) as c:
        c.spawn_log_server(poll_interval_ms=200)

        r = c.provision("acme")
        check("provision acme → 204/409", r.status in (204, 409), f"got {r.status}")
        c.deploy_handlers("acme", FIXTURE)
        c.wait_for_handler("acme", "/?mode=a", want_body="same-body", timeout_s=30.0)

        # Two identical runs and one that writes something else. All three
        # return the same body, so any difference the digest reports is about
        # behaviour rather than output.
        bodies = []
        for q in ("/?mode=a&run=1", "/?mode=a&run=2", "/?mode=b&run=3"):
            rr = c.request("acme", q, timeout=30.0)
            bodies.append((q, rr.status, rr.body))
        check("all three requests returned the same 200 body",
              all(s == 200 and b == "same-body" for _, s, b in bodies),
              repr(bodies))

        # Wait out the worker flush + poll indexing + S3 LIST lag.
        records: list[dict] = []
        deadline = time.time() + 40.0
        while time.time() < deadline:
            resp = c.log_get("acme/list?limit=50", timeout=15.0)
            if resp.status == 200:
                try:
                    records = json.loads(resp.body).get("records", [])
                except Exception:
                    records = []
            if len([r for r in records if "run=" in (r.get("path") or "")]) >= 3:
                break
            time.sleep(1.0)

        # `list` returns summaries; the tapes (and therefore the digest) live
        # on the per-record `show/` view — the same one the dashboard reads to
        # compose a replay bundle, which is what matters here.
        def show(path_needle: str):
            for rec in records:
                if path_needle in (rec.get("path") or ""):
                    rid = rec.get("request_id")
                    rr = c.log_get(f"acme/show/{rid}", timeout=15.0)
                    if rr.status != 200:
                        return None
                    full = json.loads(rr.body)
                    full = full.get("record", full)
                    return (full.get("tapes") or {}).get("interaction_digest")
            return None

        d1 = show("run=1")
        d2 = show("run=2")
        d3 = show("run=3")
        print(f"    digests: run1={d1} run2={d2} run3={d3}")

        check("record carries a non-null interaction digest", d1 is not None,
              f"got {d1!r} (null means the worker computed none, or it was dropped in transit)")
        check("identical behaviour digests identically", d1 is not None and d1 == d2,
              f"{d1} vs {d2} — something per-request is leaking into the hash")
        check("a different write digests differently despite an identical response",
              d1 is not None and d3 is not None and d1 != d3,
              f"{d1} vs {d3} — the digest is blind to a behaviour change")

    print()
    if failures:
        print(f"FAILED: {len(failures)} check(s): {', '.join(failures)}")
        return 1
    print("PASSED: the interaction digest survives capture and tracks behaviour")
    return 0


if __name__ == "__main__":
    sys.exit(main())
