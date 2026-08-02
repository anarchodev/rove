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
  3. a request that writes a DIFFERENT value AND arms a different wake digests
     differently even though its response is byte-identical — the case a
     status-only or response-only check misses entirely, which is the whole
     reason the digest exists. The handler arms a wake in both modes, so this
     also covers the effect hooks (before them, an effect-only difference
     digested as identical).
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
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
  // An EFFECT whose arguments differ by mode, with the response held
  // identical: before the effect hooks, both modes digested the same.
  after.ms(mode === "b" ? 9000 : 5000, { on: "onWake" });
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
    with V2Cluster.spawn("digest", nodes=1) as c:
        c.spawn_log_server(poll_interval_ms=200)

        r = c.provision("acme")
        check("provision acme → 200/409", r.status in (200, 409), f"got {r.status}")
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

        # ── the cross-engine half ──
        #
        # Everything above proves the worker computes and carries a digest. It
        # says nothing about whether a REPLAY of the same record computes the
        # same one — which is the property the digest exists for. Re-execute
        # the record in the replay engine and compare.
        #
        # Needs a rewind-apps checkout for the shell modules; skipped with a
        # message rather than silently passing when absent, because a check
        # that quietly does not run is worse than one that is missing.
        apps = os.environ.get("REWIND_APPS_DIR", os.path.expanduser("~/src/rewind-apps"))
        checker = os.path.join(apps, "e2e", "replay-digest-check.mjs")
        if not os.path.exists(checker):
            print(f"  SKIP cross-engine replay check — no rewind-apps checkout at {apps}")
        else:
            rid = next((r.get("request_id") for r in records if "run=1" in (r.get("path") or "")), None)
            full = json.loads(c.log_get(f"acme/show/{rid}", timeout=15.0).body)
            full = full.get("record", full)
            with tempfile.TemporaryDirectory() as td:
                rec_path = os.path.join(td, "record.json")
                src_path = os.path.join(td, "index.mjs")
                with open(rec_path, "w") as f:
                    json.dump(full, f)
                with open(src_path, "w") as f:
                    f.write(FIXTURE["index.mjs"])
                proc = subprocess.run(["node", checker, rec_path, src_path],
                                      capture_output=True, text=True, timeout=120)
            line = (proc.stdout or "").strip().splitlines()[-1] if proc.stdout.strip() else "{}"
            try:
                res = json.loads(line)
            except json.JSONDecodeError:
                res = {"replayed": None, "error": f"unparseable: {proc.stdout[:200]} {proc.stderr[:200]}"}
            print(f"    replay recomputed: {res.get('replayed')} (captured {d1})")
            for el in (res.get("effects") or []):
                print(f"      folded: {el}")
            print(f"      status={res.get('status')} result={res.get('result')!r}")
            check("a replay of the record recomputes the SAME digest",
                  res.get("replayed") is not None and res.get("replayed") == d1,
                  res.get("error") or f"replay={res.get('replayed')} vs captured={d1}")

    print()
    if failures:
        print(f"FAILED: {len(failures)} check(s): {', '.join(failures)}")
        return 1
    print("PASSED: the interaction digest survives capture and tracks behaviour")
    return 0


if __name__ == "__main__":
    sys.exit(main())
