#!/usr/bin/env python3
"""Gap 2.4 smoke — streaming inbound body via the `onChunk` export
(`docs/inbound-chunk-plan.md` S3).

Proves, against a single rewind node (direct — the front door's
streaming proxy is a separate gap):

  1. single-fire: a small body to an onChunk module fires ONCE with the
     whole body, `done = true`, `chunkSeq = 0`
  2. streaming: a 12 MB body (cap = 4 MB free tier) fires N > 1 chunk
     activations, in order, with read-your-writes across chunks (each
     fire increments a kv counter the next fire reads); the terminal
     response reports exact byte count + fires == lastSeq + 1
  3. probe fallback: a default-only module still serves a small POST
     classically (the first request probes onChunk, misses, re-walks)
  4. classic cap: a default-only module + a > cap body → 413
  5. early terminal: an onChunk module that rejects on the first chunk
     answers while the body is still inbound

Needs S3 env: `set -a; . ./.env; set +a` first.
Ports: http_base=19500 (see the per-smoke port table convention).
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

ONCHUNK_SRC = """
export function onChunk() {
  const ctx = request.ctx || { len: 0, n: 0, rw: true };
  // Per-upload kv counter (the x-upl header names the upload) — each
  // fire reads the previous fire's committed write, so `rw` proves
  // read-your-writes ordering across every chunk activation.
  const key = "upl/" + (request.headers["x-upl"] || "k");
  const prev = kv.get(key);
  const count = (prev ? Number(prev) : 0) + 1;
  kv.set(key, String(count));
  const rw = ctx.rw && count === request.chunkSeq + 1;
  const total = ctx.len + request.body.length;
  if (request.done) {
    response.status = 200;
    response.headers["content-type"] = "application/json";
    return JSON.stringify({
      fires: ctx.n + 1,
      bytes: total,
      lastSeq: request.chunkSeq,
      ordered: rw && ctx.n === request.chunkSeq,
    });
  }
  return next({ len: total, n: ctx.n + 1, rw: rw });
}
"""

REJECT_SRC = """
export function onChunk() {
  response.status = 403;
  return "rejected early";
}
"""

DEFAULT_SRC = """
export default function () {
  return "classic:" + request.body.length;
}
"""


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("ichunk", nodes=1, http_base=19500, raft_base=19560) as c:
        print("step 1: provision + deploy (onChunk, reject, default-only)")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status}")
        dep_id = c.deploy_handlers("acme", {
            "index.mjs": DEFAULT_SRC,
            "up/index.mjs": ONCHUNK_SRC,
            "reject/index.mjs": REJECT_SRC,
        })
        check("deploy", bool(dep_id))
        r = c.wait_for_handler("acme", "/", want_body="classic:")
        check("deployment serves", r.status == 200, f"got {r.status} {r.body!r}")
        host = c.host_for("acme")

        print("step 2: single fire — 1 KB body, one activation, done on seq 0")
        small = b"x" * 1024
        r = c.node_request("/up", method="POST", host=host, data=small,
                           headers={"x-upl": "small"})
        ok = r.status == 200
        body = {}
        if ok:
            try:
                body = json.loads(r.body)
            except json.JSONDecodeError:
                ok = False
        check("single fire → 200", ok, f"got {r.status} {r.body[:120]!r}")
        check("single fire: fires==1, lastSeq==0, bytes==1024",
              body.get("fires") == 1 and body.get("lastSeq") == 0 and body.get("bytes") == 1024,
              f"body={body}")

        print("step 3: streaming — 12 MB body (cap 4 MB), ordered multi-fire")
        big = os.urandom(12 * 1024 * 1024)
        r = c.node_request("/up", method="POST", host=host, data=big,
                           headers={"x-upl": "big"})
        ok = r.status == 200
        body = {}
        if ok:
            try:
                body = json.loads(r.body)
            except json.JSONDecodeError:
                ok = False
        check("streaming → 200", ok, f"got {r.status} {r.body[:120]!r}")
        check("streaming: bytes exact", body.get("bytes") == len(big), f"body={body}")
        check("streaming: multi-fire, ordered (read-your-writes)",
              body.get("lastSeq", 0) >= 1
              and body.get("fires") == body.get("lastSeq", 0) + 1
              and body.get("ordered") is True,
              f"body={body}")

        print("step 4: probe fallback — default-only module serves a POST")
        r = c.node_request("/", method="POST", host=host, data=b"hello")
        check("classic POST → 200 classic:5", r.status == 200 and "classic:5" in r.body,
              f"got {r.status} {r.body[:80]!r}")

        print("step 5: classic cap — default-only module, 5 MB body → 413")
        r = c.node_request("/", method="POST", host=host, data=b"y" * (5 * 1024 * 1024))
        check("classic >cap → 413", r.status == 413, f"got {r.status} {r.body[:80]!r}")

        print("step 6: early terminal — reject on first chunk mid-upload")
        r = c.node_request("/reject", method="POST", host=host,
                           data=os.urandom(12 * 1024 * 1024))
        # curl may see the early response cleanly (403) or the server's
        # subsequent inbound teardown as a transfer error after the
        # status arrived — accept either as long as the 403 made it out.
        check("early terminal → 403",
              r.status == 403 or "403" in r.body,
              f"got {r.status} {r.body[:120]!r}")

    print()
    if failures:
        print(f"FAILED: {len(failures)} check(s): {failures}")
        return 1
    print("inbound_chunk_smoke_v2: ALL CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
