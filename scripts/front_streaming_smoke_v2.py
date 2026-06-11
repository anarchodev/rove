#!/usr/bin/env python3
"""Front-door streaming proxy smoke — the edge-path counterpart of
`inbound_chunk_smoke_v2.py` (uploads) and `streaming_heartbeat_smoke_v2.py`
(held SSE).

Until 2026-06 the front door buffered whole request AND response bodies
through blocking libcurl calls, so chunked uploads worked direct-to-worker
only and a never-terminating SSE stream through the front never flushed a
byte. The streaming proxy (src/front/proxy.zig) relays both directions as
they arrive over a pooled h2c client leg. This smoke proves the edge path:

  1. chunked upload THROUGH the front: a 12 MB POST to an `onChunk`
     module (cap 4 MB) multi-fires at the worker with exact bytes and
     read-your-writes ordering — the front forwarded the body as it
     arrived (it exceeds the 256 KiB replay buffer, so a buffered front
     could only have delivered it whole or not at all; the assertion that
     matters is fires > 1 + bytes exact + 200 relayed).
  2. held SSE THROUGH the front: /heartbeat emits a frame immediately and
     every 200 ms; holding the request ~0.7 s must deliver ≥ 2 frames
     INCREMENTALLY through the edge (a buffering front delivers nothing
     until stream end, i.e. never).
  3. big response THROUGH the front: a handler returning a 1 MiB body
     relays intact (chunk-relay reassembly fidelity).

Needs S3 env: `set -a; . ./.env; set +a` first.
Ports: http_base=19700 (see the per-smoke port table convention).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster, rpc_wrap  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
DEMO = REPO_ROOT / "examples" / "loop46-demo-tenants"

ONCHUNK_SRC = """
export function onChunk() {
  const ctx = request.ctx || { len: 0, n: 0, rw: true };
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

BIG_SRC = """
export default function () {
  // 1 MiB of a repeating, position-dependent pattern (catches chunk
  // reordering/duplication that a constant fill would mask).
  const n = 1024 * 1024;
  const parts = [];
  for (let i = 0; parts.length * 16 < n; i++) {
    parts.push((i % 100000).toString().padStart(15, "0") + "|");
  }
  return parts.join("").slice(0, n);
}
"""

READY_SRC = 'export function handler() { return "ready"; }\n'


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("fstrm", nodes=1, http_base=19700, raft_base=19760) as c:
        print("step 1: provision + deploy (onChunk, heartbeat SSE, big, ready)")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status}")
        dep_id = c.deploy_handlers("acme", {
            "index.mjs": rpc_wrap(READY_SRC),
            "up/index.mjs": ONCHUNK_SRC,
            "big/index.mjs": BIG_SRC,
            "heartbeat/index.mjs": (DEMO / "acme/heartbeat/index.mjs").read_text(),
        })
        check("deploy", bool(dep_id))
        r = c.wait_for_handler("acme", "/?fn=handler", want_body="ready")
        check("deployment serves", r.status == 200, f"got {r.status} {r.body!r}")
        if r.status != 200:
            c.dump_node_log(grep=["deploy", "loader", "manifest", "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1
        host = c.host_for("acme")

        print("step 2: 12 MB chunked upload THROUGH the front (multi-fire onChunk)")
        big = os.urandom(12 * 1024 * 1024)
        r = c.request("acme", "/up", method="POST", data=big,
                      headers={"x-upl": "edge"}, timeout=60)
        ok = r.status == 200
        body = {}
        if ok:
            try:
                body = json.loads(r.body)
            except json.JSONDecodeError:
                ok = False
        check("upload via front → 200", ok, f"got {r.status} {r.body[:120]!r}")
        check("upload: bytes exact", body.get("bytes") == len(big), f"body={body}")
        check("upload: multi-fire, ordered (read-your-writes)",
              body.get("lastSeq", 0) >= 1
              and body.get("fires") == body.get("lastSeq", 0) + 1
              and body.get("ordered") is True,
              f"body={body}")
        if r.status != 200:
            c.dump_node_log(grep=["chunk", "error", "warn", "front"])

        print("step 3: held SSE THROUGH the front (~0.7s @ 200ms cadence)")
        url = f"{c.front_url()}/heartbeat"
        args = ["curl", "-sS", "--http2-prior-knowledge", "-N",
                "--max-time", "0.7", "-H", f"Host: {host}",
                "-D", "-", "-o", "-", "-X", "GET", url]
        proc = subprocess.run(args, capture_output=True, timeout=10)
        # curl exits 28 on --max-time; that's the expected disconnect.
        if proc.returncode not in (0, 28):
            check("held SSE via front curl exit 0/28", False,
                  f"exit={proc.returncode}: {proc.stderr.decode(errors='replace')}")
        else:
            raw = proc.stdout
            split = raw.rfind(b"\r\n\r\n")
            header_block = raw[:split].decode(errors="replace") if split >= 0 else ""
            body_s = raw[split + 4:].decode(errors="replace") if split >= 0 else ""
            headers = {}
            for line in header_block.splitlines():
                if ":" in line and not line.startswith("HTTP/"):
                    k, _, v = line.partition(":")
                    headers[k.strip().lower()] = v.strip()
            ct = headers.get("content-type", "")
            check("SSE via front: Content-Type == text/event-stream",
                  "text/event-stream" in ct, f"got {ct!r} raw[:200]={raw[:200]!r}")
            count = body_s.count(":heartbeat\n\n")
            check("SSE via front: ≥2 frames arrived INCREMENTALLY mid-stream",
                  count >= 2, f"frames={count} body={body_s!r}")

        print("step 4: 1 MiB response THROUGH the front relays intact")
        r = c.get("acme", "/big", timeout=60)
        check("GET /big via front → 200", r.status == 200, f"got {r.status}")
        want_len = 1024 * 1024
        check("big response: exact length", len(r.body) == want_len,
              f"len={len(r.body)}")
        # Spot-check the position-dependent pattern at both ends.
        check("big response: pattern intact",
              r.body.startswith("000000000000000|") and "|" in r.body[-17:],
              f"head={r.body[:32]!r} tail={r.body[-32:]!r}")

        print("step 5: HTTP/1.1 ingress at the front (classic intake + chunked relay)")
        # h1 downstream: the front's h1 codec emits body-complete requests
        # (classic intake / buffered replay) and the response relays back as
        # h1 chunked — both sides of the dual-stack edge.
        args = ["curl", "-sS", "--http1.1", "-m", "60",
                "-H", f"Host: {host}", "-o", "-",
                f"{c.front_url()}/big"]
        proc = subprocess.run(args, capture_output=True, timeout=70)
        body_h1 = proc.stdout.decode(errors="replace")
        check("h1 GET /big via front: exact length",
              proc.returncode == 0 and len(body_h1) == want_len,
              f"exit={proc.returncode} len={len(body_h1)}")
        args = ["curl", "-sS", "--http1.1", "-m", "60",
                "-H", f"Host: {host}", "-H", "x-upl: h1edge",
                "--data-binary", "@-", "-o", "-",
                f"{c.front_url()}/up"]
        proc = subprocess.run(args, input=b"y" * 4096, capture_output=True,
                              timeout=70)
        ok = proc.returncode == 0
        body = {}
        if ok:
            try:
                body = json.loads(proc.stdout.decode(errors="replace"))
            except json.JSONDecodeError:
                ok = False
        check("h1 POST via front: single fire, bytes exact",
              ok and body.get("bytes") == 4096 and body.get("fires") == 1,
              f"exit={proc.returncode} body={body or proc.stdout[:120]!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS front streaming smoke (v2): chunked upload, held SSE, and a "
          "1 MiB response all relay through the front door incrementally")
    return 0


if __name__ == "__main__":
    sys.exit(main())
