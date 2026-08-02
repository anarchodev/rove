#!/usr/bin/env python3
"""A wake armed FROM A RESUME activation actually arms.

`after.ms` / `after.kv` append to `pending_wakes`, which the inbound dispatch
wired but the three `worker_drain` resume sites (bound-fetch chunk,
inbound-chunk, send_callback) left null — so a held chain that re-armed a
wake from one of those resumes hit the null accumulator, the arm silently
dropped, and (post-#139) the re-park then failed the wake-source vigilance
with a defined `500 held with no wake source`.

This drives the issue's headline scenario end to end on the bound-fetch
resume (`resumeBoundFetchChain`), through the WRITE repark (so the installed
`StreamWakes` must ride the raft_pending_cont round-trip back into
`parked_continuations`):

  GET /holdfetch?url=<wb/bulk>
    → default hop binds a buffered `after.fetch(url)` (no `{on}`) + next()
    → the whole upstream body arrives in ONE `onFetchResult` (fetch_chunk
      resume): persist its length in kv (writing hop), arm a FRESH
      `after.kv("rearm/wake/", {on:"onWake"})`, and re-park with next()
    → a separate `GET /poke` writes `rearm/wake/x`, firing the re-armed kv
      wake → `onWake` returns 200 `woke:<len>`.

Before the fix the held request never resumes (500 held-no-wake, or a 25 s
504 hang without the vigilance); after it, the wake arms and delivers.

Upstream `wb/bulk` is reused verbatim from the on.fetch demo tenants (a
deterministic 170-byte body). Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import concurrent.futures
import sys
import time
import urllib.parse as up
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, PUBLIC_SUFFIX, rpc_wrap  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEMO = REPO_ROOT / "examples" / "loop46-demo-tenants"


def _src(rel: str) -> str:
    return (DEMO / rel).read_text()


EXPECTED_BODY = "".join(f"bulk-line-{i:02d}-zzz\n" for i in range(10))
FETCHED_LEN = len(EXPECTED_BODY)  # 170

# The default hop binds a buffered on.fetch and holds. The result lands in
# `onFetchResult` (the bound-fetch chunk resume) — which arms a FRESH kv wake
# and re-parks. That arm is exactly the one a resume-armed wake must not drop.
HOLDFETCH_SRC = """\
export default function () {
    const q = request.query || "";
    let url = null;
    for (const pair of q.split("&")) {
        const eq = pair.indexOf("=");
        if (eq < 0) continue;
        if (decodeURIComponent(pair.slice(0, eq)) === "url")
            url = decodeURIComponent(pair.slice(eq + 1));
    }
    if (!url) { response.status = 400; return "missing ?url="; }
    after.fetch(url);            // buffered (no {on}) → onFetchResult
    return next();
}

// Bound-fetch chunk resume (resumeBoundFetchChain). Writing hop (kv.set) →
// WRITE repark: the after.kv arm must survive the raft round-trip.
export function onFetchResult() {
    kv.set("rearm/fetched", String((request.text || "").length));
    after.kv("rearm/wake/", { on: "onWake" });
    return next();
}

export function onWake() {
    response.status = 200;
    return "woke:" + (kv.get("rearm/fetched") || "?");
}
"""

# A separate inbound write that fires the re-armed kv wake on the held chain.
POKE_SRC = """\
export default function () {
    kv.set("rearm/wake/x", "go");
    response.status = 204;
    return "";
}
"""

READY_SRC = 'export function handler() { return "ready"; }\n'

WB_HANDLERS = {
    "index.mjs": _src("wb/index.mjs"),
    "bulk/index.mjs": _src("wb/bulk/index.mjs"),
}


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("rearmwake", nodes=1) as c:
        print("step 1: provision + deploy acme (holdfetch/poke) and wb (bulk upstream)")
        r = c.provision("acme")
        check("provision acme → 200", r.status == 200, f"got {r.status} {r.body!r}")
        r = c.provision("wb")
        check("provision wb → 200", r.status == 200, f"got {r.status} {r.body!r}")
        try:
            c.deploy_handlers("acme", {
                "index.mjs": rpc_wrap(READY_SRC),
                "holdfetch/index.mjs": HOLDFETCH_SRC,
                "poke/index.mjs": POKE_SRC,
            })
            c.deploy_handlers("wb", WB_HANDLERS)
            check("deploy acme + wb", True)
        except RuntimeError as e:
            check("deploy acme + wb", False, str(e))
            print("\nFAILURES:", failures)
            return 1

        r = c.wait_for_handler("wb", "/bulk", want_status=200,
                               want_body=EXPECTED_BODY, timeout_s=25.0)
        check("wb/bulk upstream reachable + byte-exact",
              r.status == 200 and r.body == EXPECTED_BODY,
              f"status={r.status} len={len(r.body)}")
        ready = c.wait_for_handler("acme", "/?fn=handler", want_body="ready", timeout_s=25.0)
        check("acme deployment loaded", ready.status == 200, f"got {ready.status} {ready.body!r}")
        if failures:
            c.dump_node_log(grep=["deploy", "loader", "manifest", "resolve", "error", "warn"])
            print("\nFAILURES:", failures)
            return 1

        bulk_url = f"http://wb.{PUBLIC_SUFFIX}:{c.front_port}/bulk"

        def held():
            return c.get("acme", f"/holdfetch?url={up.quote(bulk_url)}", timeout=30.0)

        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            fut = pool.submit(held)
            # Let the fetch complete + onFetchResult arm after.kv + re-park
            # before the poke fires the re-armed wake.
            time.sleep(1.5)
            p = c.get("acme", "/poke", timeout=10.0)
            check("poke → 204", p.status == 204, f"got {p.status} {p.body!r}")
            r = fut.result(timeout=35.0)

        # The core #140 assertion: the held chain resumed via the wake armed
        # from the fetch_chunk resume — not 500 held-no-wake, not a 504 hang.
        check("held /holdfetch resumed → 200 (wake armed from the resume)",
              r.status == 200, f"got {r.status} {r.body!r}")
        check("onWake ran with the persisted fetched length",
              r.body == f"woke:{FETCHED_LEN}", f"got {r.body!r} want 'woke:{FETCHED_LEN}'")
        if r.status != 200:
            c.dump_node_log(grep=["wake source", "held", "fetch", "kv", "wake",
                                  "park", "resume", "error", "warn"])

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS resume-rearm-wake smoke (v2): after.kv armed from a "
          "bound-fetch resume arms + delivers (issue #140)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
