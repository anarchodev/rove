#!/usr/bin/env python3
"""The serve-side shred gate: a record leaves the logs door OPENED, or it
does not leave at all.

A value sealed under a per-identity key (`shredKey`) is sealed at
the WRITE boundary, so the ciphertext propagates by itself into every
container below — including the execution tape. That is the mechanism, not
an accident: opening before the tape append would put plaintext on the
tape and defeat the whole scheme.

Which leaves someone having to open it on the way OUT, and that someone is
the worker's `rewind-logs.internal` door — the one place that holds both
the tenant's keys and the completeness watermark saying whether a miss
means anything.

The proof is a CONTRAST, because either half alone proves nothing:

  * read the record straight off the log-server (no door, no keys) and the
    tape must hold CIPHERTEXT. Without this, "the door returned plaintext"
    is equally consistent with the tape never having been sealed at all;
  * read the same record through the door and the tape must hold
    PLAINTEXT — which is also what makes the interaction digest
    recomputable, since the digest folds the value the handler READ;
  * destroy the identity, read again through the door, and the tape must
    be sealed once more. That is the erasure, and the still-sealed value
    is what the downstream transcode turns into a refusal naming the
    reason (`src/replay/export_fixture.zig`).

Needs S3 env: `set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import base64
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

# The value whose bytes every assertion here is about. Distinctive enough
# that finding it is never a coincidence.
MARKER = "sardine-serve-gate-7c41"

# `seal` writes under an identity; `read` is a SEPARATE activation that
# reads the stored value back, which is the one that puts ciphertext on
# the kv tape. A read in the same activation as the write comes off the
# overlay and is plaintext there — it would prove nothing.
# Hand-composed default (the rpc_wrap recipe forwards no activation object
# to named functions, and `shredKey` is a capability on it — rove#849):
# destructure the caps once, route on ?fn= internally. Same wire as every
# rpc_wrap smoke.
SRC = (
    'export default function ({ shredKey }) {\n'
    '  const fn = ((request.query || "").match(/fn=([^&]+)/) || [])[1];\n'
    '  const fns = {\n'
    '    seal() {\n'
    '      shredKey("u_serve");\n'
    '      kv.set("card", "' + MARKER + '");\n'
    '      return "sealed\\n";\n'
    '    },\n'
    '    read() {\n'
    '      shredKey("u_serve");\n'
    '      return "read:" + kv.get("card") + "\\n";\n'
    '    },\n'
    '    erase() {\n'
    '      shredKey.destroy("u_serve");\n'
    '      return "erased\\n";\n'
    '    },\n'
    '  };\n'
    '  const f = fns[fn];\n'
    '  if (!f) { response.status = 404; return "no such fn: " + fn; }\n'
    '  return f();\n'
    '}\n'
)

# Reads ONE record back through the privileged door — the gate under test.
# Self-tenant, so the engine pins the read to this handler's own id.
PROBE_SRC = r"""export default function () {
    const rid = new URLSearchParams(request.query || "").get("rid") || "";
    after.fetch("http://rewind-logs.internal/v1/" + request.tenant + "/show/" + rid);
    return next();
}
export function onFetchResult() {
    response.status = 200;
    return "status:" + (request.status || 0) + "\n" + (request.text || "");
}
"""

# A STREAMED read of the same door. The gate rewrites a whole response
# body, which a streamed transfer never has in hand, so the door refuses
# rather than handing the chunks over unopened.
STREAM_SRC = r"""export default function () {
    const rid = new URLSearchParams(request.query || "").get("rid") || "";
    after.fetch("http://rewind-logs.internal/v1/" + request.tenant + "/show/" + rid,
                { stream: true });
    return next();
}
export function onFetchChunk() { return next(); }
export function onFetchDone() {
    response.status = 200;
    return "status:" + (request.status || 0) + "\n";
}
"""

FIXTURE = {
    "index.mjs": SRC,
    "probe/index.mjs": PROBE_SRC,
    "streamprobe/index.mjs": STREAM_SRC,
}

SEAL_MARKER = 0xFF


def kv_tape(record_json: str) -> bytes:
    """The decoded kv tape of the one record in a `/show` response."""
    doc = json.loads(record_json)
    rec = doc.get("record", doc)
    b64 = (rec.get("tapes") or {}).get("kv_tape_b64")
    return base64.b64decode(b64) if b64 else b""


def door_show(c, rid: str):
    """`/show/{rid}` THROUGH the worker door. Returns (status, tape bytes)."""
    r = c.request("acme", "/probe?rid=" + rid, timeout=30.0)
    head, _, body = r.body.partition("\n")
    status = int(head.split(":", 1)[1]) if head.startswith("status:") else 0
    if status < 200 or status >= 300:
        return status, b""
    return status, kv_tape(body)


def main() -> int:
    failures: list[str] = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    print("=== serve-side shred gate (logs door opens a record, or refuses it) ===")
    with V2Cluster.spawn("shredserve", nodes=1) as c:
        c.spawn_log_server()
        c._ensure_admin_app()

        r = c.provision("acme")
        check("provision acme → 200/409", r.status in (200, 409),
              f"got {r.status} {r.body!r}")
        try:
            c.deploy_handlers("acme", FIXTURE)
        except RuntimeError as e:
            check("deploy acme", False, str(e))
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print("step 1: seal a value under an identity, then READ it back")
        r = c.wait_for_handler("acme", "/?fn=seal", want_body="sealed", timeout_s=45.0)
        check("sealed write → 200", r.status == 200 and "sealed" in r.body,
              f"got {r.status} {r.body!r}")
        r = c.request("acme", "/?fn=read", timeout=30.0)
        check("the handler reads its own value back as PLAINTEXT",
              r.status == 200 and MARKER in r.body, f"got {r.status} {r.body!r}")

        print("step 2: find that read activation's record")
        deadline = time.time() + 60.0
        rid = None
        while time.time() < deadline and rid is None:
            lr = c.log_get("acme/list?limit=50")
            if lr.status == 200:
                for rec in json.loads(lr.body).get("records", []):
                    # `?fn=read` is the rpc_wrap spelling of the read hop.
                    if "fn=read" in (rec.get("path") or ""):
                        rid = rec.get("request_id")
                        break
            if rid is None:
                time.sleep(1.0)
        check("the read activation is indexed", rid is not None, f"rid={rid}")
        if rid is None:
            print(f"\nFAILURES ({len(failures)}): {failures}")
            return 1

        print("step 3: CONTROL — straight off the log-server, the tape is CIPHERTEXT")
        # No door, no keys. If this shows plaintext then the value was never
        # sealed on the tape and every assertion below is about nothing.
        raw = c.log_get(f"acme/show/{rid}")
        check("direct /show → 200", raw.status == 200, f"got {raw.status} {raw.body!r}")
        raw_tape = kv_tape(raw.body) if raw.status == 200 else b""
        check("CONTROL: the raw tape carries the seal marker",
              SEAL_MARKER in raw_tape,
              "no 0xFF on the tape — the read was never sealed, so the gate "
              "below proves nothing")
        check("CONTROL: the raw tape does NOT carry the plaintext",
              MARKER.encode() not in raw_tape,
              "the plaintext is on the tape unsealed")

        print("step 4: THE GATE — through the door, the same tape is PLAINTEXT")
        status, tape = door_show(c, rid)
        check("door /show → 200", status == 200, f"got {status}")
        check("the door opened the sealed value",
              MARKER.encode() in tape,
              "the tape came back sealed — the gate did not open it, and "
              "replay would read a live identity as erased")
        check("no ciphertext survives the door",
              SEAL_MARKER not in tape, "a seal marker is still on the served tape")

        print("step 5: destroy the identity — the same record goes back to sealed")
        r = c.request("acme", "/?fn=erase", timeout=30.0)
        check("destroy → 200", r.status == 200 and "erased" in r.body,
              f"got {r.status} {r.body!r}")

        # The destroy is durable through raft and the shard rewrite follows,
        # so poll rather than assume the very next read has settled.
        deadline = time.time() + 60.0
        tape = b""
        status = 0
        while time.time() < deadline:
            status, tape = door_show(c, rid)
            if status == 200 and SEAL_MARKER in tape:
                break
            time.sleep(1.0)
        check("door /show still → 200 after the erasure", status == 200, f"got {status}")
        check("the erased value is served STILL SEALED",
              SEAL_MARKER in tape,
              "the door served something else — a sealed value whose key is "
              "gone must reach the transcode sealed, which is what turns it "
              "into a refusal that names the erasure")
        check("the plaintext is gone from the served record",
              MARKER.encode() not in tape, "the plaintext survived the erasure")

        print("step 6: a STREAMED read of the door is refused, not served unopened")
        # The gate needs the whole body. A streamed transfer never has one,
        # so serving it would hand out ciphertext — and hand a customer a
        # way to ask for it. Refusing is the only honest option.
        #
        # The SAME url step 4 read successfully, so the stream flag is the
        # only difference between a 200 and this refusal — otherwise
        # `status:0` would be satisfied by any broken fetch.
        r = c.request("acme", "/streamprobe?rid=" + rid, timeout=30.0)
        check("streamed logs-door fetch → refused",
              r.status == 200 and "status:0" in r.body,
              f"got {r.status} {r.body!r}")

    if failures:
        print(f"\nFAILED ({len(failures)}): {failures}")
        return 1
    print("\nPASS — the door opened a live identity's record, served an "
          "erased one still sealed, and refused a streamed read.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
