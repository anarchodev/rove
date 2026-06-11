#!/usr/bin/env python3
"""h1 inbound body streaming (rove-h2 edge; the h1 mirror of
`inbound_body_smoke_v2.py` + `inbound_chunk_smoke_v2.py`).

Until 2026-06 the h1 codec emitted body-complete requests only: an h1
upload buffered whole at the edge (16 MiB backstop) and the worker saw
one complete body. Now an incomplete-at-parse h1 body early-emits into
`request_receiving` (synthetic StreamId 1) and streams through the same
BodyMode machinery as h2 — `requestBodyBuffer` (classic), the
inbound-chunk sink (`onChunk`), socket-read parking as backpressure in
place of window debt, and the decision-gated `100 Continue`.

Proves, direct-to-worker AND through the front door:
  1. 12 MB h1 Content-Length upload → multi-fire `onChunk`, byte-exact,
     read-your-writes ordered (streamed, not buffered: 12 MB ≫ the 1 MiB
     read-pause cap, so the backpressure parking is on the hot path).
  2. h1 chunked Transfer-Encoding upload → byte-exact through the
     incremental decode path.
  3. h1 upload to a default-export module → classic buffering decided
     MID-STREAM (`requestBodyBuffer` h1 branch), sha256 byte-exact.
  4. `Expect: 100-continue` + onHeaders early reply: 401 from headers
     alone — the body is never sent and the connection closes out
     cleanly (the never-told-to-proceed close rule).

Needs S3 env: `set -a; . ./.env; set +a` first.
Ports: http_base=24100 (see the per-smoke port table convention).
"""

from __future__ import annotations

import hashlib
import json
import os
import random
import string
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

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

HASH_SRC = """\
export default function () {
    const data = request.body || "";
    return crypto.sha256(data) + ":" + data.length;
}
"""

ONHEADERS_SRC = """\
export function onHeaders() {
    if (!request.headers["x-upload-auth"]) {
        response.status = 401;
        return "unauthorized";
    }
    return "accepted:" + (request.body || "").length;
}
export default function () {
    return "default-ran";
}
"""

READY_SRC = 'export function handler() { return "ready"; }\n'


def h1_curl(url: str, host: str, *, data: bytes | None = None,
            headers: dict | None = None, timeout: int = 90):
    """HTTP/1.1 request → (exit, status, body). Tolerates exit 55 with a
    complete response (early reply + upload cut, same rule as _curl)."""
    args = ["curl", "-sS", "--http1.1", "-D", "-", "-o", "-",
            "-m", str(timeout), "-H", f"Host: {host}"]
    for k, v in (headers or {}).items():
        args += ["-H", f"{k}: {v}"]
    if data is not None:
        args += ["--data-binary", "@-"]
    args.append(url)
    proc = subprocess.run(args, input=data if data is not None else b"",
                          capture_output=True, timeout=timeout + 10)
    raw = proc.stdout
    ok_exit = proc.returncode == 0 or (proc.returncode == 55 and b"\r\n\r\n" in raw)
    if not ok_exit:
        return proc.returncode, 0, proc.stderr.decode(errors="replace")
    # Skip interim 100 Continue header blocks: status = last HTTP/ line.
    split = raw.rfind(b"\r\n\r\n")
    head = raw[:split].decode(errors="replace") if split >= 0 else ""
    body = raw[split + 4:] if split >= 0 else b""
    status = 0
    for line in head.splitlines():
        if line.startswith("HTTP/"):
            parts = line.split(" ", 2)
            if len(parts) >= 2 and parts[1].isdigit():
                status = int(parts[1])
    return proc.returncode, status, body.decode(errors="replace")


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    with V2Cluster.spawn("h1strm", nodes=1, http_base=24100, raft_base=24160) as c:
        print("step 1: provision + deploy (onChunk, hash, onHeaders)")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status}")
        dep_id = c.deploy_handlers("acme", {
            "index.mjs": READY_SRC,
            "up/index.mjs": ONCHUNK_SRC,
            "hash/index.mjs": HASH_SRC,
            "upload/index.mjs": ONHEADERS_SRC,
        })
        check("deploy", bool(dep_id))
        r = c.wait_for_handler("acme", "/?fn=handler", want_body="ready")
        check("deployment serves", r.status == 200, f"got {r.status} {r.body!r}")
        if r.status != 200:
            c.dump_node_log(grep=["deploy", "loader", "error", "warn"])
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1
        host = c.host_for("acme")
        worker = c.node_url(0)
        front = c.front_url()

        for label, base in (("worker-direct", worker), ("via front", front)):
            print(f"step 2 ({label}): 12 MB h1 Content-Length upload → onChunk multi-fire")
            big = os.urandom(12 * 1024 * 1024)
            exit_, status, body_s = h1_curl(f"{base}/up", host, data=big,
                                            headers={"x-upl": f"h1cl-{label[:3]}"})
            body = {}
            ok = status == 200
            if ok:
                try:
                    body = json.loads(body_s)
                except json.JSONDecodeError:
                    ok = False
            check(f"h1 12MB upload ({label}) → 200", ok,
                  f"exit={exit_} status={status} body={body_s[:120]!r}")
            check(f"h1 12MB ({label}): bytes exact", body.get("bytes") == len(big),
                  f"body={body}")
            check(f"h1 12MB ({label}): multi-fire, ordered",
                  body.get("lastSeq", 0) >= 1
                  and body.get("fires") == body.get("lastSeq", 0) + 1
                  and body.get("ordered") is True,
                  f"body={body}")

            print(f"step 3 ({label}): h1 chunked Transfer-Encoding upload → byte count exact")
            data = os.urandom(6 * 1024 * 1024)
            exit_, status, body_s = h1_curl(f"{base}/up", host, data=data,
                                            headers={"x-upl": f"h1te-{label[:3]}",
                                                     "Transfer-Encoding": "chunked"})
            body = {}
            ok = status == 200
            if ok:
                try:
                    body = json.loads(body_s)
                except json.JSONDecodeError:
                    ok = False
            check(f"h1 chunked upload ({label}) → 200", ok,
                  f"exit={exit_} status={status} body={body_s[:120]!r}")
            check(f"h1 chunked ({label}): bytes exact", body.get("bytes") == len(data),
                  f"body={body}")

            print(f"step 4 ({label}): h1 3 MB upload → default export (classic buffer mid-stream)")
            # ASCII body — request.body is a JS string; random bytes decode
            # lossily (same caveat as inbound_body_smoke_v2).
            rng = random.Random(7)
            blob = "".join(rng.choices(string.ascii_letters + string.digits,
                                       k=3 * 1024 * 1024)).encode()
            want = hashlib.sha256(blob).hexdigest()
            exit_, status, body_s = h1_curl(f"{base}/hash", host, data=blob,
                                            headers={"content-type": "application/octet-stream"})
            check(f"h1 classic POST ({label}) → 200 sha256 exact",
                  status == 200 and body_s.strip() == f"{want}:{len(blob)}",
                  f"exit={exit_} status={status} got={body_s[:90]!r}")

            print(f"step 5 ({label}): Expect: 100-continue + onHeaders early 401")
            exit_, status, body_s = h1_curl(f"{base}/upload", host,
                                            data=b"z" * (3 * 1024 * 1024),
                                            headers={"content-type": "application/octet-stream"})
            check(f"h1 Expect + early 401 ({label})",
                  status == 401 and "unauthorized" in body_s,
                  f"exit={exit_} status={status} body={body_s[:90]!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS h1 streaming smoke (v2): h1 uploads stream from the edge — "
          "onChunk multi-fire, chunked decode, classic mid-stream buffering, "
          "and the Expect early-reply close-out, direct AND through the front")
    return 0


if __name__ == "__main__":
    sys.exit(main())
