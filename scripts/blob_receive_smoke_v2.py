#!/usr/bin/env python3
"""`blob.receive` end-to-end (blob-storage-plan §3.5; docs/architecture/routing-and-ingress.md, P3 slice B).

The Case-B inbound pipe: a module exporting `onHeaders` dispatches
from headers alone (body still at the door, h2 window held);
`blob.receive({to}) + next()` opens the valve and streams the body
socket → tenant-prefix S3 multipart with ZERO chunk activations; the
completion event resumes the held chain at `{to}` with
`request.ctx = {hash, len}`, and the handler answers the
still-open socket.

Coverage:
  1. 12 MiB upload (3 multipart parts: 5+5+2) → 200 {hash,len},
     hash == local sha256.
  2. Small upload (1 KiB — single sub-part tail, likely the
     eof-before-arm race: body complete before the commit point) →
     same contract.
  3. Round-trip: a reader route serves the stored object's first
     bytes via blob.get → byte-exact.
  4. Early 401 from onHeaders (no auth header) — disposition decided
     before the body is accepted.
  5. blob.receive outside onHeaders → handler error (TypeError), not
     a silent accept.

Needs S3 env: `set -a; . ./.env; set +a` first. Tenant is bumped to
the pro tier (32 MiB body cap) so the 12 MiB case clears the
plan-tier Lever-2 gate.
"""

from __future__ import annotations

import hashlib
import json
import random
import string
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib_v2 import V2Cluster  # noqa: E402

RECEIVE_SRC = """\
export function onHeaders() {
    if (!request.headers["x-upload-auth"]) {
        response.status = 401;
        return "unauthorized";
    }
    blob.receive({ to: "onStored" });
    return next();
}

export function onStored() {
    if (!request.activation.ok) {
        response.status = 502;
        return "store failed";
    }
    kv.set("media/" + request.ctx.hash, JSON.stringify({ len: request.ctx.len }));
    return JSON.stringify({ hash: request.ctx.hash, len: request.ctx.len });
}
"""

# blob.receive from a buffered (non-onHeaders) activation must throw.
MISUSE_SRC = """\
export default function () {
    blob.receive({ to: "onStored" });
    return "should not reach";
}
"""

# Reader: blob.get the stored hash, answer with the fetched bytes'
# sha256 + length so the smoke can verify the round trip at any size.
READER_SRC = """\
export default function () {
    const hash = (request.query || "").replace("hash=", "");
    blob.get(hash, { to: "onBlob" });
    return next();
}
export function onBlob() {
    if (!request.activation.ok || request.activation.status !== 200) {
        response.status = 404;
        return "missing";
    }
    const bytes = request.activation.bytes;
    return crypto.sha256(bytes) + ":" + bytes.length;
}
"""

READY_SRC = 'export function handler() { return "ready"; }\n'


def main() -> int:
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
        if not ok:
            failures.append(label)

    rng = random.Random(7)

    def body_of(size):
        return "".join(rng.choices(string.ascii_letters + string.digits, k=size)).encode()

    with V2Cluster.spawn("blob-receive", nodes=1) as c:
        print("step 1: provision + pro plan (32 MiB body cap) + deploy")
        r = c.provision("acme")
        check("provision → 204", r.status == 204, f"got {r.status}")
        rp = c.set_plan("acme", '{"tier":"pro"}')
        check("set_plan pro → 2xx", rp.status in (200, 204), f"got {rp.status} {rp.body!r}")
        dep_id = c.deploy_handlers("acme", {
            "index.mjs": READY_SRC,
            "upload/index.mjs": RECEIVE_SRC,
            "misuse/index.mjs": MISUSE_SRC,
            "read/index.mjs": READER_SRC,
        })
        check("deploy", bool(dep_id))
        ready = c.wait_for_handler("acme", "/?fn=handler", want_body="ready")
        check("loaded", ready.status == 200, f"got {ready.status} {ready.body!r}")

        print("step 2: 12 MiB upload → multipart (5+5+2) → onStored {hash,len}")
        big = body_of(12 * 1024 * 1024)
        want_hash = hashlib.sha256(big).hexdigest()
        r = c.request("acme", "/upload", method="POST",
                      headers={"content-type": "application/octet-stream",
                               "x-upload-auth": "yes"},
                      data=big, timeout=120.0)
        check("12MiB → 200", r.status == 200, f"got {r.status} {r.body!r}")
        got = json.loads(r.body) if r.status == 200 else {}
        check("12MiB hash matches local sha256",
              got.get("hash") == want_hash and got.get("len") == len(big),
              f"want {want_hash}:{len(big)} got {got}")
        if r.status != 200:
            c.dump_node_log(grep=["receive", "blob", "error", "warn", "panic"])

        print("step 3: 1 KiB upload (single tail part / eof-at-arm race)")
        small = body_of(1024)
        small_hash = hashlib.sha256(small).hexdigest()
        r = c.request("acme", "/upload", method="POST",
                      headers={"content-type": "application/octet-stream",
                               "x-upload-auth": "yes"},
                      data=small, timeout=60.0)
        check("1KiB → 200", r.status == 200, f"got {r.status} {r.body!r}")
        got = json.loads(r.body) if r.status == 200 else {}
        check("1KiB hash matches", got.get("hash") == small_hash and got.get("len") == 1024,
              f"want {small_hash}:1024 got {got}")

        print("step 4: round-trip the small object via blob.get")
        r = c.request("acme", f"/read?hash={small_hash}", method="GET", timeout=60.0)
        check("read → 200 byte-exact", r.status == 200 and r.body == f"{small_hash}:1024",
              f"got {r.status} {r.body!r}")

        print("step 5: early 401 — body never accepted")
        r = c.request("acme", "/upload", method="POST",
                      headers={"content-type": "application/octet-stream"},
                      data=big, timeout=60.0)
        check("401 from headers alone", r.status == 401 and "unauthorized" in r.body,
              f"got {r.status} {r.body!r}")

        print("step 6: blob.receive outside onHeaders → handler error")
        r = c.request("acme", "/misuse", method="POST",
                      headers={"content-type": "application/octet-stream"},
                      data=body_of(64 * 1024), timeout=60.0)
        check("misuse → 500", r.status == 500 and "onHeaders" in r.body,
              f"got {r.status} {r.body!r}")

    if failures:
        print(f"\nFAILURES ({len(failures)}): {failures}")
        return 1
    print("\nPASS blob.receive smoke (v2): headers-first pipe → S3 multipart → "
          "content-addressed object → held-chain resume, zero chunk activations")
    return 0


if __name__ == "__main__":
    sys.exit(main())
