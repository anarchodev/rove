#!/usr/bin/env python3
"""blob.* P1+P2 smoke — `docs/architecture/routing-and-ingress.md` exit checks.

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
  5. P2 `blob.write`/`blob.seal` sessions: (a) mirror — a streamed
     `on.fetch` of our own presigned URL, one `blob.write` per chunk
     resume, `seal` on final; content addressing self-validates (the
     mirrored object's hash must equal the source's); (b) gen —
     eight writes in one activation, seal, hash compared to a
     python-side sha256 of the same content; round-tripped via
     presigned URL (large bodies don't materialize in JS — arena).

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
  // Unified flattened on_result surface (handler-shape §7, Endpoint A):
  // request.ok/.status top-level, blob hash on request.activation.hash,
  // echoed context IS request.ctx.
  kv.set("put_result", JSON.stringify({
    result: { ok: request.ok, status: request.status, hash: request.activation.hash },
    context: request.ctx,
  }));
}
"""

# P2 mirror flow: stream an upstream object (here: a presigned URL of
# our own put object, hex-encoded to survive the query string) chunk
# by chunk through blob.write, seal, and return the resulting hash.
# Content addressing makes the test self-validating: mirrored bytes
# must produce the ORIGINAL object's hash.
MIRROR_SRC = """
export default function () {
  const src = new TextDecoder().decode(
    hex.decode(request.path.slice(request.path.indexOf("src=") + 4)));
  on.fetch(src, { stream: true, max_response_chunk_bytes: 16384 },
           { to: "onChunk" });
  return next();
}

export function onChunk() {
  if (!request.done) {
    if (request.body && request.body.length) blob.write(request.body);
    return next();
  }
  const hash = blob.seal({ to: "onStored", content_type: "text/plain" });
  return next({ hash });
}

export function onStored() {
  if (request.status !== 200) {
    response.status = 502;
    return "seal PUT failed: " + request.status;
  }
  return request.ctx.hash;
}
"""

# P2 multi-write-in-one-activation flow: JS-generated content, eight
# blob.write calls, seal — the smoke compares against a python-side
# sha256 of the same deterministic content.
GEN_CHUNK = "rewindjs-blob-p2!" * 1024  # 17 KiB
GEN_SRC = f"""
export default function () {{
  let chunk = "";
  for (let i = 0; i < 1024; i++) chunk += "rewindjs-blob-p2!";
  for (let i = 0; i < 8; i++) blob.write(chunk);
  const hash = blob.seal({{ to: "onStored" }});
  return next({{ hash }});
}}

export function onStored() {{
  if (request.status !== 200) {{
    response.status = 502;
    return "seal PUT failed: " + request.status;
  }}
  return request.ctx.hash;
}}
"""

# Held route (next()) ⇒ module-per-route. Reads one record: hot →
# sync return; sealed → blob.get of the segment resumes onSeg, which
# slices via the recipe helper.
SEGGET_SRC = """
export default function () {
  const qpos = request.path.indexOf("?");
  const q = {};
  for (const pair of request.path.slice(qpos + 1).split("&")) {
    const eq = pair.indexOf("=");
    if (eq > 0) q[pair.slice(0, eq)] = pair.slice(eq + 1);
  }
  const v = segments.get(q.stream, Number(q.seq), { to: "onSeg" });
  if (typeof v === "string") return "hot:" + v;
  if (v === null) { response.status = 404; return "missing"; }
  return next();
}

export function onSeg() {
  if (!request.done) return next();
  if (request.status !== 200) { response.status = 502; return "segment fetch failed"; }
  return "sealed:" + segments.slice(request);
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
  if (path === "/seg-append") {
    const n = Number(q.n || "1");
    let first = -1, last = -1;
    for (let i = 0; i < n; i++) {
      // Each record embeds its own seq so reads are self-checking.
      const nx = Number(kv.get("_seg/" + q.stream + "/n") ?? "0");
      const seq = segments.append(q.stream, "v-" + nx);
      if (first < 0) first = seq;
      last = seq;
    }
    return JSON.stringify({ first, last });
  }
  if (path === "/seg-seal") {
    return String(segments.seal(q.stream, { min: 1 }));
  }
  if (path === "/seg-check") {
    const hot = kv.prefix("_seg/" + q.stream + "/h/", null, 4096);
    const segs = kv.prefix("_seg/" + q.stream + "/s/", null, 4096);
    return JSON.stringify({ hot: hot.length, segs: segs.map((r) => JSON.parse(r.value)) });
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
                "mirror/index.mjs": MIRROR_SRC,
                "gen/index.mjs": GEN_SRC,
                "segget/index.mjs": SEGGET_SRC,
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

        print("step 6: P2 mirror — streamed fetch → blob.write per chunk → seal")
        src_hex = url.encode().hex()
        r = c.request(TENANT, f"/mirror?src={src_hex}", timeout=60.0)
        check("mirror route → 200", r.status == 200, f"got {r.status} {r.body!r}")
        mirrored = (r.body.decode() if isinstance(r.body, bytes) else str(r.body)).strip()
        check("mirrored hash == original hash (CAS self-validation)",
              mirrored == expect_hash, f"got {mirrored!r} want {expect_hash!r}")

        print("step 7: P2 multi-write — 8 writes in one activation → seal")
        gen_expect = hashlib.sha256((GEN_CHUNK * 8).encode()).hexdigest()
        r = c.request(TENANT, "/gen", timeout=60.0)
        check("gen route → 200", r.status == 200, f"got {r.status} {r.body!r}")
        gen_hash = (r.body.decode() if isinstance(r.body, bytes) else str(r.body)).strip()
        check("gen hash == python sha256 of same content",
              gen_hash == gen_expect, f"got {gen_hash!r} want {gen_expect!r}")
        # Round-trip the sealed object BOTH ways: through the door
        # (blob.get + native TextDecoder over a 139 KB body — this
        # exact read OOM'd the pre-native pure-JS decoder) and via
        # the presigned URL (independent of the worker entirely).
        r = c.request(TENANT, f"/get?hash={gen_expect}", timeout=30.0)
        got = r.body.decode() if isinstance(r.body, bytes) else str(r.body)
        check("sealed gen object round-trips via blob.get (139 KB decode)",
              r.status == 200 and got == GEN_CHUNK * 8,
              f"status {r.status} len {len(got)}")
        r = c.request(TENANT, f"/url?hash={gen_expect}")
        gen_url = (r.body.decode() if isinstance(r.body, bytes) else str(r.body)).strip()
        try:
            with urllib.request.urlopen(gen_url, timeout=15) as resp:
                direct = resp.read().decode()
            check("sealed gen object round-trips via presigned URL",
                  direct == GEN_CHUNK * 8, f"len {len(direct)}")
        except Exception as e:  # noqa: BLE001
            check("sealed gen object round-trips via presigned URL", False, str(e))

        print("step 8: P4 segments — append, hot read, seal, sealed read")
        r = c.request(TENANT, "/seg-append?stream=sm&n=6")
        check("append 6 → seqs 0..5", r.status == 200 and json.loads(r.body) == {"first": 0, "last": 5},
              f"got {r.status} {r.body!r}")
        r = c.request(TENANT, "/segget?stream=sm&seq=2", timeout=30.0)
        body = r.body.decode() if isinstance(r.body, bytes) else str(r.body)
        check("hot read seq 2", r.status == 200 and body == "hot:v-2", f"got {r.status} {body!r}")
        r = c.request(TENANT, "/seg-seal?stream=sm")
        body = r.body.decode() if isinstance(r.body, bytes) else str(r.body)
        check("seal → 6 rows", r.status == 200 and body.strip() == "6", f"got {r.status} {body!r}")
        swapped = None
        deadline = time.time() + 30.0
        while time.time() < deadline:
            rc = c.request(TENANT, "/seg-check?stream=sm")
            if rc.status == 200:
                st = json.loads(rc.body)
                if st["hot"] == 0 and len(st["segs"]) == 1:
                    swapped = st
                    break
            time.sleep(0.5)
        check("swap: hot rows gone, 1 index row", swapped is not None,
              "swap never landed in 30s")
        if swapped:
            seg = swapped["segs"][0]
            check("index row covers 0..5",
                  seg["first_seq"] == 0 and seg["last_seq"] == 5 and seg["count"] == 6,
                  f"got {seg!r}")
        r = c.request(TENANT, "/segget?stream=sm&seq=2", timeout=30.0)
        body = r.body.decode() if isinstance(r.body, bytes) else str(r.body)
        check("sealed read seq 2 (blob.get + slice)",
              r.status == 200 and body == "sealed:v-2", f"got {r.status} {body!r}")
        r = c.request(TENANT, "/seg-append?stream=sm&n=2")
        check("counter survives seal (next seqs 6..7)",
              r.status == 200 and json.loads(r.body) == {"first": 6, "last": 7},
              f"got {r.status} {r.body!r}")
        r = c.request(TENANT, "/segget?stream=sm&seq=6", timeout=30.0)
        body = r.body.decode() if isinstance(r.body, bytes) else str(r.body)
        check("post-seal hot read seq 6", r.status == 200 and body == "hot:v-6",
              f"got {r.status} {body!r}")

    print(f"\n{PASS} passed, {FAIL} failed")
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
