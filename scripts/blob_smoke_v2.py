#!/usr/bin/env python3
"""blob.* P1 smoke — `docs/blob-storage-plan.md` P1 exit check.

Proves the customer blob surface end to end on the real V2 stack
against real S3 (the V2 blob backend is S3-only):

  1. `blob.put`: a deployed handler stores bytes and returns the
     sha256 synchronously (matches a local digest of the same bytes);
     the engine-signed PUT lands in the tenant's `app-blobs/` prefix;
     the `_blob/owed/{hash}` marker settles (cleared by
     `__system/blob_onresult`); the customer `on_result` module fires
     with `ok: true`.
  2. `blob.get`: a second request reads the object back through the
     signed `rove-blob.internal` door (connection-scoped `on.fetch`
     composition, `{to}` export routing) — bytes round-trip.
  3. `blob.url`: a presigned GET URL minted by the handler is fetched
     DIRECTLY from this test process (zero worker involvement) and
     returns the bytes with the signed content-type — proves the
     query-mode SigV4 path + per-tenant prefix isolation end to end.
  4. Hash validation: `blob.url` on a malformed hash → handler throws
     → 500 (the trusted door never sees a non-digest key).

Needs S3 env (`set -a; . ./.env; set +a`) and binaries:
`zig build rewind rewind-cp rewind-front files-server-v2`.

Port base 18700 (see the per-smoke port table convention).
"""

from __future__ import annotations

import hashlib
import json
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

TENANT = "blobtest"

# Route `/get` lives in its own module (`get/index.mjs`): the
# bound-fetch resume resolves the module FROM THE PATH (`get/index`),
# so a held route can't lean on the index.mjs fallback the way plain
# request/response routes can.
GET_SRC = """
export default function () {
  const qpos = request.path.indexOf("?");
  const hash = request.path.slice(request.path.indexOf("hash=") + 5);
  blob.get(hash, { to: "onBlob" });
  return next();
}

export function onBlob() {
  if (!request.done) return next();
  const body = request.body instanceof Uint8Array
    ? new TextDecoder().decode(request.body)
    : String(request.body ?? "");
  if (request.status !== 200) {
    response.status = 502;
    return "blob.get failed: " + request.status;
  }
  return body;
}
"""

# `on_result` is a MODULE path (default export runs as a fresh
# connectionless activation), not a `module/export` pair.
PUTRESULT_SRC = """
export default function () {
  const ctx = JSON.parse(request.body).ctx;
  kv.set("put_result", JSON.stringify({ result: ctx.result, context: ctx.context }));
}
"""

HANDLER_SRC = """
export default function () {
  const qpos = request.path.indexOf("?");
  const path = qpos < 0 ? request.path : request.path.slice(0, qpos);
  const q = {};
  if (qpos >= 0) {
    for (const pair of request.path.slice(qpos + 1).split("&")) {
      const eq = pair.indexOf("=");
      if (eq > 0) q[pair.slice(0, eq)] = pair.slice(eq + 1);
    }
  }
  if (path === "/put") {
    const body = request.body || "";
    const hash = blob.put(body, {
      content_type: "text/plain",
      on_result: "putresult",
      context: { tag: "smoke" },
    });
    kv.set("last_put", hash);
    return hash;
  }
  if (path === "/url") {
    return blob.url(q.hash, { ttl: 300, content_type: "text/plain" });
  }
  if (path === "/check") {
    const owed = kv.get("_blob/owed/" + q.hash);
    const pr = kv.get("put_result");
    return JSON.stringify({ owed: owed ? JSON.parse(owed) : null,
                            put_result: pr ? JSON.parse(pr) : null });
  }
  if (path === "/") return "ready";
  response.status = 404;
  return "no such route";
}
"""

PASS = 0
FAIL = 0


def check(name: str, ok: bool, detail: str = "") -> None:
    global PASS, FAIL
    if ok:
        PASS += 1
        print(f"  ok   {name}")
    else:
        FAIL += 1
        print(f"  FAIL {name}: {detail}")


def main() -> int:
    with V2Cluster.spawn("blob", http_base=18700) as c:
        print("step 1: provision + deploy the blob handler")
        r = c.provision(TENANT)
        check("provision → 204", r.status == 204, f"got {r.status} {r.body!r}")
        try:
            c.deploy_handlers(TENANT, {
                "index.mjs": HANDLER_SRC,
                "get/index.mjs": GET_SRC,
                "putresult.mjs": PUTRESULT_SRC,
            })
        except Exception as e:  # noqa: BLE001
            check("deploy_handlers", False, str(e))
            return 1
        ready = c.wait_for_handler(TENANT, "/", want_body="ready")
        check("handler ready", ready, "never served 'ready'")
        if not ready:
            c.dump_node_log(grep=["blob", "error", "warn"])
            return 1

        # Unique body per run so a stale marker from a previous run
        # can't masquerade as this run's settle.
        body = f"hello blob world {time.time_ns()}"
        expect_hash = hashlib.sha256(body.encode()).hexdigest()

        print("step 2: blob.put — sync hash + marker settle + on_result")
        r = c.request(TENANT, "/put", method="POST", data=body)
        check("PUT route → 200", r.status == 200, f"got {r.status} {r.body!r}")
        got_hash = r.body.decode() if isinstance(r.body, bytes) else str(r.body)
        check("returned hash == local sha256", got_hash == expect_hash,
              f"got {got_hash!r} want {expect_hash!r}")

        settled = None
        deadline = time.time() + 30.0
        while time.time() < deadline:
            rc = c.request(TENANT, f"/check?hash={expect_hash}")
            if rc.status == 200:
                st = json.loads(rc.body)
                if st["owed"] is None and st["put_result"] is not None:
                    settled = st
                    break
            time.sleep(0.5)
        check("owed marker cleared", settled is not None,
              "marker still present (or put_result missing) after 30s")
        if settled:
            res = settled["put_result"]["result"]
            check("on_result ok:true", res.get("ok") is True and res.get("hash") == expect_hash,
                  f"got {res!r}")
            check("on_result context echoed",
                  settled["put_result"]["context"] == {"tag": "smoke"},
                  f"got {settled['put_result']['context']!r}")

        print("step 3: blob.get — read back through the signed door")
        r = c.request(TENANT, f"/get?hash={expect_hash}", timeout=30.0)
        check("GET route → 200", r.status == 200, f"got {r.status} {r.body!r}")
        got_body = r.body.decode() if isinstance(r.body, bytes) else str(r.body)
        check("blob.get round-trips bytes", got_body == body,
              f"got {got_body!r}")

        print("step 4: blob.url — presigned URL fetched directly (no worker)")
        r = c.request(TENANT, f"/url?hash={expect_hash}")
        check("URL route → 200", r.status == 200, f"got {r.status} {r.body!r}")
        url = (r.body.decode() if isinstance(r.body, bytes) else str(r.body)).strip()
        check("presigned URL shape", "X-Amz-Signature=" in url and expect_hash in url,
              f"got {url!r}")
        try:
            with urllib.request.urlopen(url, timeout=15) as resp:
                direct = resp.read().decode()
                ct = resp.headers.get("content-type", "")
            check("direct S3 fetch → bytes match", direct == body, f"got {direct!r}")
            check("signed content-type honored", ct.startswith("text/plain"),
                  f"got {ct!r}")
        except Exception as e:  # noqa: BLE001
            check("direct S3 fetch", False, str(e))

        print("step 5: malformed hash rejected before the door")
        r = c.request(TENANT, "/url?hash=nothex")
        check("bad hash → 500", r.status == 500, f"got {r.status} {r.body!r}")

    print(f"\n{PASS} passed, {FAIL} failed")
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
